import Foundation

/// A timestamped measurement (HealthKit quantity sample, already in display units).
public struct TimedValue: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let value: Double
    /// HealthKit source name (e.g. "Alvin's Apple Watch"), for provenance only.
    /// Never part of fingerprints, de-duplication or scoring.
    public var source: String?

    public init(start: Date, end: Date, value: Double, source: String? = nil) {
        self.start = start
        self.end = end
        self.value = value
        self.source = source
    }
}

/// One HRV reading kept with the day, so the displayed HRV can be traced to
/// exactly the samples the recovery score used.
public struct HRVReading: Codable, Sendable, Equatable, Identifiable {
    public var date: Date
    public var sdnnMs: Double
    /// True when the reading falls in the window the score uses (main sleep
    /// bout, or 20:00-10:00 without sleep). Only these form `lnHRV`.
    public var usedByScore: Bool
    public var source: String?
    public var id: Date { date }

    public init(date: Date, sdnnMs: Double, usedByScore: Bool, source: String? = nil) {
        self.date = date
        self.sdnnMs = sdnnMs
        self.usedByScore = usedByScore
        self.source = source
    }
}

/// An HKWorkout reduced to what diagnostics need. Workouts do not feed the
/// score directly: training load comes from heart rate. They are used to
/// confirm that sessions were recorded and that heart rate covered them.
public struct WorkoutSample: Sendable, Equatable {
    public let start: Date
    public let end: Date
    /// `HKWorkoutActivityType.rawValue`.
    public let activityType: UInt
    /// HealthKit object UUID: the stable identity used to reconcile Margin's
    /// own logs with Health (see `ActivityReconciler`).
    public var healthID: UUID?
    public var source: String?

    public init(start: Date, end: Date, activityType: UInt, healthID: UUID? = nil, source: String? = nil) {
        self.start = start
        self.end = end
        self.activityType = activityType
        self.healthID = healthID
        self.source = source
    }
}

public struct WorkoutDaySummary: Codable, Sendable, Equatable {
    /// Workouts that *started* in the activity window (a workout spanning
    /// midnight is counted once, on the day it started).
    public var started: Int = 0
    /// Workout minutes falling inside the activity window (split across midnight).
    public var minutes: Double = 0
    /// Fraction of in-window workout time covered by heart-rate samples.
    public var heartRateCoverage: Double?
    public var latestEnd: Date?

    public init() {}
}

/// The exact time windows a day was built with. Stored with the record so a
/// rebuilt day keeps its original boundaries even after a time-zone change.
public struct DayWindows: Codable, Sendable, Equatable {
    /// Sleep ending in this window is attributed to the day.
    public var night: DateInterval
    /// Training load, workouts and Apple resting HR.
    public var activity: DateInterval
    /// HRV / respiration window used only when no sleep was detected.
    public var fallbackOvernight: DateInterval
    public var timeZoneID: String

    public init(night: DateInterval, activity: DateInterval, fallbackOvernight: DateInterval, timeZoneID: String) {
        self.night = night
        self.activity = activity
        self.fallbackOvernight = fallbackOvernight
        self.timeZoneID = timeZoneID
    }

    /// Smallest interval covering every window: what must be fetched for the day.
    public var union: DateInterval {
        let start = min(night.start, activity.start, fallbackOvernight.start)
        let end = max(night.end, activity.end, fallbackOvernight.end)
        return DateInterval(start: start, end: end)
    }

    public static func nominal(for day: Day, calendar: Calendar) -> DayWindows {
        DayWindows(night: day.nightWindow(calendar: calendar),
                   activity: day.calendarWindow(calendar: calendar),
                   fallbackOvernight: day.fallbackOvernightWindow(calendar: calendar),
                   timeZoneID: calendar.timeZone.identifier)
    }

    /// Nominal windows, except that the night and activity windows start
    /// exactly where the previous day's stored windows ended. Consecutive days
    /// therefore tile time with no overlap (double counting) and no gap
    /// (lost data) when the time zone changes between them.
    public static func chained(for day: Day, calendar: Calendar, previous: DayWindows?) -> DayWindows {
        var w = nominal(for: day, calendar: calendar)
        guard let p = previous else { return w }
        let maxShift: TimeInterval = 18 * 3600
        if abs(p.activity.end.timeIntervalSince(w.activity.start)) <= maxShift {
            let start = p.activity.end
            w.activity = DateInterval(start: start, end: max(w.activity.end, start.addingTimeInterval(3600)))
        }
        if abs(p.night.end.timeIntervalSince(w.night.start)) <= maxShift {
            let start = p.night.end
            w.night = DateInterval(start: start, end: max(w.night.end, start.addingTimeInterval(3600)))
        }
        return w
    }
}

/// Parameter-independent daily aggregates. Cached on device; all scores are
/// recomputed from these, so changing settings never requires a re-query.
public struct DayRecord: Codable, Sendable, Equatable {
    /// v2: windows, ingestion stats, workouts, fingerprint, plausibility filtering.
    /// v3: hourly slices (stress, strain by hour, energy), workout details with
    /// heart-rate recovery, step totals.
    /// v4: per-workout time at heart rate (custom zones, cardio focus).
    /// v5: HRV readings with timestamps and sources, respiration sample count,
    /// workout Health UUIDs and sources (provenance; aggregates unchanged).
    public static let schemaVersion = 5

    public let day: Day
    public var sleep: SleepNight?
    /// Mean of ln(SDNN ms) over the main sleep bout (or fallback overnight window).
    public var lnHRV: Double?
    public var hrvSampleCount: Int
    public var hrvDuringSleep: Bool
    /// 10th percentile of heart rate during the main sleep bout.
    public var sleepingHR: Double?
    public var sleepingHRSampleCount: Int
    /// Apple's daily resting heart rate for this calendar day.
    public var appleRestingHR: Double?
    public var respiratoryRate: Double?
    public var wristTemperature: Double?
    /// Time-at-heart-rate for the activity window.
    public var activity: HeartRateHistogram
    public var workouts: WorkoutDaySummary
    public var ingestion: IngestionStats
    /// Nil only for records constructed directly (tests); built records always carry windows.
    public var windows: DayWindows?
    public var builtAt: Date?
    /// See `SourceFingerprint`.
    public var sourceFingerprint: String?
    /// Hours of the activity window that have any data, oldest first.
    public var hours: [HourSlice]
    /// Workouts that started in the activity window, with heart-rate recovery.
    public var workoutDetails: [WorkoutDetail]
    /// Steps in the activity window.
    public var steps: Double
    /// Every accepted HRV reading in the day's fetch interval, oldest first.
    public var hrvReadings: [HRVReading]
    public var respiratorySampleCount: Int

    public var coverageHours: Double { activity.totalSeconds / 3600 }

    /// True when no input produced any accepted sample for this day.
    public var isEmpty: Bool {
        sleep == nil && lnHRV == nil && sleepingHR == nil && appleRestingHR == nil
            && respiratoryRate == nil && wristTemperature == nil && activity.totalSeconds == 0
            && workouts.started == 0
    }

    public init(day: Day,
                sleep: SleepNight? = nil,
                lnHRV: Double? = nil,
                hrvSampleCount: Int = 0,
                hrvDuringSleep: Bool = false,
                sleepingHR: Double? = nil,
                sleepingHRSampleCount: Int = 0,
                appleRestingHR: Double? = nil,
                respiratoryRate: Double? = nil,
                wristTemperature: Double? = nil,
                activity: HeartRateHistogram = HeartRateHistogram(),
                workouts: WorkoutDaySummary = WorkoutDaySummary(),
                ingestion: IngestionStats = IngestionStats(),
                windows: DayWindows? = nil,
                builtAt: Date? = nil,
                sourceFingerprint: String? = nil,
                hours: [HourSlice] = [],
                workoutDetails: [WorkoutDetail] = [],
                steps: Double = 0,
                hrvReadings: [HRVReading] = [],
                respiratorySampleCount: Int = 0) {
        self.day = day
        self.sleep = sleep
        self.lnHRV = lnHRV
        self.hrvSampleCount = hrvSampleCount
        self.hrvDuringSleep = hrvDuringSleep
        self.sleepingHR = sleepingHR
        self.sleepingHRSampleCount = sleepingHRSampleCount
        self.appleRestingHR = appleRestingHR
        self.respiratoryRate = respiratoryRate
        self.wristTemperature = wristTemperature
        self.activity = activity
        self.workouts = workouts
        self.ingestion = ingestion
        self.windows = windows
        self.builtAt = builtAt
        self.sourceFingerprint = sourceFingerprint
        self.hours = hours
        self.workoutDetails = workoutDetails
        self.steps = steps
        self.hrvReadings = hrvReadings
        self.respiratorySampleCount = respiratorySampleCount
    }
}

public struct RawDayInput: Sendable {
    public var sleep: [SleepSegment]
    /// SDNN in milliseconds.
    public var hrv: [TimedValue]
    public var heartRate: [HRSample]
    public var restingHR: [TimedValue]
    public var respiratoryRate: [TimedValue]
    /// Degrees Celsius.
    public var wristTemperature: [TimedValue]
    public var workouts: [WorkoutSample]
    /// Step counts (value = steps over the sample interval).
    public var steps: [TimedValue]
    /// Apple's one-minute heart-rate recovery samples (bpm drop).
    public var heartRateRecovery: [TimedValue]

    public init(sleep: [SleepSegment] = [], hrv: [TimedValue] = [], heartRate: [HRSample] = [],
                restingHR: [TimedValue] = [], respiratoryRate: [TimedValue] = [],
                wristTemperature: [TimedValue] = [], workouts: [WorkoutSample] = [],
                steps: [TimedValue] = [], heartRateRecovery: [TimedValue] = []) {
        self.sleep = sleep
        self.hrv = hrv
        self.heartRate = heartRate
        self.restingHR = restingHR
        self.respiratoryRate = respiratoryRate
        self.wristTemperature = wristTemperature
        self.workouts = workouts
        self.steps = steps
        self.heartRateRecovery = heartRateRecovery
    }

    /// Union of all nominal windows `DayRecordBuilder` reads for `day`.
    public static func fetchInterval(for day: Day, calendar: Calendar) -> DateInterval {
        DayWindows.nominal(for: day, calendar: calendar).union
    }
}

public enum DayRecordBuilder {
    /// Convenience for tests and callers without stored windows: nominal windows, no future filtering.
    public static func build(day: Day, calendar: Calendar, input: RawDayInput,
                             params: ModelParameters = .standard) -> DayRecord {
        build(day: day, windows: .nominal(for: day, calendar: calendar), input: input,
              asOf: .distantFuture, builtAt: nil, params: params)
    }

    /// Inputs may contain samples outside the day; each field filters to its own window.
    /// Samples are de-duplicated, range-checked and future-filtered first; every
    /// rejection is counted in `ingestion`.
    public static func build(day: Day, windows: DayWindows, input: RawDayInput, asOf: Date,
                             builtAt: Date?, params: ModelParameters = .standard) -> DayRecord {
        let limits = params.plausibility
        let union = windows.union
        var stats = IngestionStats()

        let sleepIn = Sanitizer.sleep(input.sleep, within: union, asOf: asOf, limits: limits, stats: &stats[.sleep])
        let hrvIn = Sanitizer.timed(input.hrv, range: limits.hrvSDNN, within: union, asOf: asOf,
                                    limits: limits, stats: &stats[.hrv])
        let hrIn = Sanitizer.heartRate(input.heartRate, within: union, asOf: asOf, limits: limits, stats: &stats[.heartRate])
        let rhrIn = Sanitizer.timed(input.restingHR, range: limits.restingHR, within: union, asOf: asOf,
                                    limits: limits, stats: &stats[.restingHR])
        let rrIn = Sanitizer.timed(input.respiratoryRate, range: limits.respiratoryRate, within: union, asOf: asOf,
                                   limits: limits, stats: &stats[.respiratoryRate])
        let tempIn = Sanitizer.timed(input.wristTemperature, range: limits.wristTemperature, within: union, asOf: asOf,
                                     limits: limits, stats: &stats[.wristTemperature])
        let workoutsIn = Sanitizer.workouts(input.workouts, within: union, asOf: asOf, limits: limits,
                                            stats: &stats[.workouts])
        let stepsIn = Sanitizer.timed(input.steps, range: limits.steps, within: union, asOf: asOf,
                                      limits: limits, stats: &stats[.steps])
        let hrrIn = Sanitizer.timed(input.heartRateRecovery, range: limits.heartRateRecovery, within: union,
                                    asOf: asOf, limits: limits, stats: &stats[.heartRateRecovery])

        let night = SleepAggregator.aggregate(segments: sleepIn, window: windows.night,
                                              boutMergeGap: params.sleepBoutMergeGap)
        let overnight = night.map { DateInterval(start: $0.mainOnset, end: $0.mainWake) } ?? windows.fallbackOvernight
        func inOvernight(_ d: Date) -> Bool { d >= overnight.start && d <= overnight.end }

        let hrvValues = hrvIn.filter { inOvernight($0.start) }.map { log($0.value) }

        var sleepingHR: Double?
        var sleepingHRCount = 0
        if let n = night {
            let hrs = hrIn.filter { $0.date >= n.mainOnset && $0.date <= n.mainWake }.map(\.bpm)
            sleepingHRCount = hrs.count
            if hrs.count >= params.minSleepHRSamples {
                sleepingHR = Stats.quantile(hrs, params.sleepingHRQuantile)
            }
        }

        let act = windows.activity
        let rhr = rhrIn.filter { $0.start >= act.start && $0.start < act.end }.map(\.value)
        let rr = rrIn.filter { inOvernight($0.start) }.map(\.value)
        let temp = tempIn.filter { $0.end > windows.night.start && $0.end <= windows.night.end }.map(\.value)
        let stepsInDay = stepsIn.filter { $0.start >= act.start && $0.start < act.end }
        let workoutsStarted = workoutsIn.filter { $0.start >= act.start && $0.start < act.end }

        return DayRecord(
            day: day,
            sleep: night,
            lnHRV: Stats.mean(hrvValues),
            hrvSampleCount: hrvValues.count,
            hrvDuringSleep: night != nil && !hrvValues.isEmpty,
            sleepingHR: sleepingHR,
            sleepingHRSampleCount: sleepingHRCount,
            appleRestingHR: Stats.mean(rhr),
            respiratoryRate: Stats.mean(rr),
            wristTemperature: Stats.mean(temp),
            activity: HeartRateHistogram.build(samples: hrIn, window: act, maxGap: params.maxSampleGap),
            workouts: WorkoutAggregator.summarize(workoutsIn, heartRate: hrIn, window: act, maxGap: params.maxSampleGap),
            ingestion: stats,
            windows: windows,
            builtAt: builtAt,
            sourceFingerprint: SourceFingerprint.compute(windows: windows, input: input, asOf: asOf, limits: limits),
            hours: HourSliceBuilder.build(heartRate: hrIn, steps: stepsIn, sleep: sleepIn, workouts: workoutsIn,
                                          window: act, params: params),
            workoutDetails: WorkoutRecoveryAnalyzer.analyze(workouts: workoutsStarted, heartRate: hrIn,
                                                            appleRecovery: hrrIn, params: params),
            steps: stepsInDay.reduce(0) { $0 + $1.value },
            hrvReadings: hrvIn.map { HRVReading(date: $0.start, sdnnMs: $0.value, usedByScore: inOvernight($0.start), source: $0.source) },
            respiratorySampleCount: rr.count
        )
    }
}

public enum WorkoutAggregator {
    public static func summarize(_ workouts: [WorkoutSample], heartRate: [HRSample],
                                 window: DateInterval, maxGap: TimeInterval) -> WorkoutDaySummary {
        var s = WorkoutDaySummary()
        let sortedHR = heartRate.sorted { $0.date < $1.date }
        var inWindowSeconds = 0.0, coveredSeconds = 0.0
        for w in workouts {
            if w.start >= window.start && w.start < window.end { s.started += 1 }
            let start = max(w.start, window.start), end = min(w.end, window.end)
            guard end > start else { continue }
            inWindowSeconds += end.timeIntervalSince(start)
            coveredSeconds += covered(sortedHR, from: start, to: end, maxGap: maxGap)
            s.latestEnd = max(s.latestEnd ?? w.end, w.end)
        }
        s.minutes = inWindowSeconds / 60
        s.heartRateCoverage = inWindowSeconds > 0 ? min(coveredSeconds / inWindowSeconds, 1) : nil
        return s
    }

    /// Seconds of [from, to) covered by HR samples, each holding until the next (capped).
    static func covered(_ hr: [HRSample], from: Date, to: Date, maxGap: TimeInterval) -> Double {
        var total = 0.0
        let inside = hr.filter { $0.date >= from && $0.date < to }
        for (i, s) in inside.enumerated() {
            let next = i + 1 < inside.count ? inside[i + 1].date : to
            total += min(max(next.timeIntervalSince(s.date), 0), maxGap)
        }
        return total
    }
}
