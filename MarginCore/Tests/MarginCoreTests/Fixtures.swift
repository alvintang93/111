import Foundation
@testable import MarginCore

/// What one night/day of raw HealthKit-shaped data should contain.
struct NightSpec {
    var hrvMs: Double? = 55
    var sleepingHR: Double? = 50
    var asleepHours: Double? = 7.5
    var respiratory: Double? = 14
    var temperature: Double? = 34.5
    var restingHR: Double? = 55
    var workoutMinutes: Double = 45
    var workoutBPM: Double = 145
    var daytimeHR = true
}

/// Builds HealthKit-shaped raw samples for a run of days, so tests exercise the
/// real ingestion -> build -> plan -> score path instead of hand-made records.
enum RawFixture {
    static func input(days: [Day], calendar: Calendar = testCalendar, spec: (Day) -> NightSpec?) -> RawDayInput {
        var input = RawDayInput()
        for day in days {
            guard let s = spec(day) else { continue }
            let prev = day.adding(-1, calendar: calendar)
            let onset = prev.date(hour: 23, calendar: calendar)
            if let h = s.asleepHours {
                let wake = onset.addingTimeInterval(h * 3600)
                input.sleep.append(SleepSegment(start: onset, end: wake, stage: .core, sourcePriority: 2))
                if let hrv = s.hrvMs {
                    for offset in [1.0, 3.0, 5.0] where offset < h {
                        let t = onset.addingTimeInterval(offset * 3600)
                        input.hrv.append(TimedValue(start: t, end: t.addingTimeInterval(60), value: hrv))
                    }
                }
                if let bpm = s.sleepingHR {
                    var t = onset, k = 0
                    while t <= wake {
                        input.heartRate.append(HRSample(date: t, bpm: bpm + Double(k % 5)))
                        t = t.addingTimeInterval(300)
                        k += 1
                    }
                }
                if let rr = s.respiratory {
                    for offset in [2.0, 4.0] where offset < h {
                        let t = onset.addingTimeInterval(offset * 3600)
                        input.respiratoryRate.append(TimedValue(start: t, end: t.addingTimeInterval(60), value: rr))
                    }
                }
                if let temp = s.temperature {
                    input.wristTemperature.append(TimedValue(start: onset, end: wake, value: temp))
                }
            } else if let hrv = s.hrvMs {
                // No sleep recorded: HRV lands in the fallback overnight window.
                let t = day.date(hour: 4, calendar: calendar)
                input.hrv.append(TimedValue(start: t, end: t.addingTimeInterval(60), value: hrv))
            }
            if s.daytimeHR {
                var t = day.date(hour: 8, calendar: calendar)
                let end = day.date(hour: 22, calendar: calendar)
                while t < end {
                    input.heartRate.append(HRSample(date: t, bpm: 65))
                    t = t.addingTimeInterval(300)
                }
            }
            if s.workoutMinutes > 0 {
                let start = day.date(hour: 18, calendar: calendar).addingTimeInterval(60)
                let end = start.addingTimeInterval(s.workoutMinutes * 60)
                var t = start
                while t < end {
                    input.heartRate.append(HRSample(date: t, bpm: s.workoutBPM))
                    t = t.addingTimeInterval(5)
                }
                input.workouts.append(WorkoutSample(start: start, end: end, activityType: 37))
            }
            if let rhr = s.restingHR {
                let t = day.date(hour: 12, calendar: calendar)
                input.restingHR.append(TimedValue(start: t, end: t.addingTimeInterval(60), value: rhr))
            }
        }
        return input
    }

    /// Stationary physiology with deterministic noise; `override` replaces specific days.
    static func noisySpec(seed: UInt64, override: [Day: NightSpec?] = [:]) -> (Day) -> NightSpec? {
        var rng = SeededNormal(seed: seed)
        var cache: [Day: NightSpec?] = [:]
        return { day in
            if let o = override[day] { return o }
            if let c = cache[day] { return c }
            var s = NightSpec()
            s.hrvMs = 55 * exp(0.10 * rng.next())
            s.sleepingHR = (50 + 1.5 * rng.next()).rounded()
            s.asleepHours = 7.6 + 0.4 * rng.next()
            s.respiratory = 14 + 0.4 * rng.next()
            s.temperature = 34.5 + 0.15 * rng.next()
            cache[day] = s
            return s
        }
    }
}

/// Runs the production planner + builder over raw input, like the app does.
struct PipelineHarness {
    var calendar = testCalendar
    var records: [Day: DayRecord] = [:]
    var lastPlan: SyncPlan?

    @discardableResult
    mutating func sync(today: Day, now: Date, input: RawDayInput, mode: SyncMode = .foreground,
                       params: SyncParameters = .standard) -> SyncPlan {
        let fps = mode == .foreground
            ? SyncPlanner.fingerprints(for: records, input: input, asOf: now, calendar: calendar) : nil
        let plan = SyncPlanner.plan(existing: records, today: today, calendar: calendar, now: now, mode: mode,
                                    currentFingerprints: fps, params: params)
        for item in plan.items {
            records[item.day] = DayRecordBuilder.build(day: item.day, windows: item.windows, input: input,
                                                       asOf: now, builtAt: now)
        }
        lastPlan = plan
        return plan
    }

    func brief(today: Day, now: Date, settings: UserSettings = UserSettings(age: 35, sex: .male)) -> DailyBrief {
        Engine(records: Array(records.values), today: today, settings: settings, calendar: calendar, asOf: now)
            .brief(generatedAt: now, dataSyncedAt: now)
    }
}
