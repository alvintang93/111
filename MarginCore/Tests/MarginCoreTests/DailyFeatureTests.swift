import XCTest
@testable import MarginCore

/// Batch 1: hourly slices, strain, stress, energy, heart-rate recovery,
/// caffeine and hydration, activity status, timeline and dashboard tiles.
final class DailyFeatureTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }
    var window: DateInterval { today.calendarWindow(calendar: cal) }

    func hr(from: Date, to: Date, bpm: Double, every: TimeInterval = 60) -> [HRSample] {
        stride(from: 0, to: to.timeIntervalSince(from), by: every).map { HRSample(date: from.addingTimeInterval($0), bpm: bpm) }
    }

    // MARK: Hourly slices

    func testSlicesAddUpToTheDailyHistogram() {
        let samples = hr(from: at(today, 7, 13), to: at(today, 22, 41), bpm: 72, every: 47)
            + hr(from: at(today, 18), to: at(today, 19), bpm: 150, every: 5)
        let sorted = samples.sorted { $0.date < $1.date }
        let slices = HourSliceBuilder.build(heartRate: sorted, steps: [], sleep: [], workouts: [], window: window)
        let histogram = HeartRateHistogram.build(samples: sorted, window: window, maxGap: 300)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.hrSeconds }, histogram.totalSeconds, accuracy: 1e-6)
        XCTAssertEqual(slices.first?.hour, 7)
        XCTAssertEqual(slices.last?.hour, 22)
    }

    func testRestStateExcludesSleepWorkoutsAndMovement() {
        var samples = hr(from: at(today, 0), to: at(today, 6), bpm: 50)          // asleep
        samples += hr(from: at(today, 9), to: at(today, 10), bpm: 70)            // still: rest
        samples += hr(from: at(today, 12), to: at(today, 13), bpm: 100)          // walking
        samples += hr(from: at(today, 18), to: at(today, 19), bpm: 150)          // workout
        samples += hr(from: at(today, 19), to: at(today, 20), bpm: 90)           // first 10 min settle
        let sleep = [SleepSegment(start: at(today.adding(-1, calendar: cal), 23), end: at(today, 6), stage: .core, sourcePriority: 2)]
        let steps = [TimedValue(start: at(today, 12), end: at(today, 13), value: 6000)]
        let workouts = [WorkoutSample(start: at(today, 18), end: at(today, 19), activityType: 37)]
        let slices = Dictionary(uniqueKeysWithValues: HourSliceBuilder.build(
            heartRate: samples, steps: steps, sleep: sleep, workouts: workouts, window: window).map { ($0.hour, $0) })

        XCTAssertEqual(slices[3]!.restSeconds, 0)
        XCTAssertEqual(slices[3]!.asleepSeconds, 3600, accuracy: 1e-6)
        XCTAssertEqual(slices[9]!.restSeconds, 3600, accuracy: 1e-6)
        XCTAssertEqual(slices[9]!.restMeanBPM!, 70, accuracy: 1e-9)
        XCTAssertEqual(slices[12]!.restSeconds, 0)
        XCTAssertEqual(slices[12]!.steps, 6000, accuracy: 1e-6)
        XCTAssertEqual(slices[18]!.restSeconds, 0)
        XCTAssertEqual(slices[18]!.workoutSeconds, 3600, accuracy: 1e-6)
        XCTAssertEqual(slices[19]!.restSeconds, 3000, accuracy: 1e-6, "10-minute settle after the workout")
    }

    func testStepsAreProratedAcrossHours() {
        let steps = [TimedValue(start: at(today, 10, 30), end: at(today, 11, 30), value: 1000)]
        let slices = HourSliceBuilder.build(heartRate: [], steps: steps, sleep: [], workouts: [], window: window)
        XCTAssertEqual(slices.map(\.steps), [500, 500])
    }

    // MARK: Strain

    func testStrainCurve() {
        XCTAssertEqual(StrainModel.score(load: 0, reference: 60), 0)
        XCTAssertEqual(StrainModel.score(load: 60, reference: 60), 50, accuracy: 1e-9)
        XCTAssertEqual(StrainModel.score(load: 120, reference: 60), 75, accuracy: 1e-9)
        XCTAssertLessThan(StrainModel.score(load: 10_000, reference: 60), 100.0000001)
    }

    func testStrainUsesChronicLoadAndHourlyAddsUp() throws {
        let days = Day.range(from: today.adding(-89, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let now = at(today, 21)
        h.sync(today: today, now: now, input: RawFixture.input(days: days, spec: RawFixture.noisySpec(seed: 5)))
        let b = h.brief(today: today, now: now)
        let s = try XCTUnwrap(b.strain)
        XCTAssertEqual(s.reference, .chronicLoad)
        XCTAssertEqual(s.referenceLoad, b.load.ctl!, accuracy: 1e-9)
        XCTAssertEqual(s.hourly.reduce(0) { $0 + $1.value }, b.load.todayLoad!, accuracy: 1e-6)
        XCTAssertNotNil(s.score)
        XCTAssertNotNil(s.targetLow)
    }

    func testStrainIsProvisionalWithoutLoadHistory() {
        let days = Day.range(from: today.adding(-5, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let now = at(today, 21)
        h.sync(today: today, now: now, input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        let s = h.brief(today: today, now: now).strain!
        XCTAssertEqual(s.reference, .provisional)
        XCTAssertEqual(s.referenceLoad, ModelParameters.standard.strainFallbackReference)
    }

    // MARK: Stress

    func testStressLevelScale() {
        let p = ModelParameters.standard
        XCTAssertEqual(StressModel.level(meanBPM: 55, hrRest: 55, hrMax: 185, params: p), 0)
        XCTAssertEqual(StressModel.level(meanBPM: 55 + 0.30 * 130, hrRest: 55, hrMax: 185, params: p), 100)
        XCTAssertEqual(StressModel.level(meanBPM: 55 + 0.15 * 130, hrRest: 55, hrMax: 185, params: p), 50)
        XCTAssertEqual(StressModel.level(meanBPM: 40, hrRest: 55, hrMax: 185, params: p), 0)
        XCTAssertEqual(StressBand(level: 25), .rest)
        XCTAssertEqual(StressBand(level: 26), .low)
        XCTAssertEqual(StressBand(level: 76), .high)
    }

    func testStressNeedsEnoughRestTime() {
        let p = ModelParameters.standard
        let short = HourSlice(hour: 9, restSeconds: 5 * 60, restBPMSeconds: 70 * 5 * 60)
        let long = HourSlice(hour: 10, restSeconds: 50 * 60, restBPMSeconds: 75 * 50 * 60)
        let s = StressModel.summarize(slices: [short, long], windowStart: window.start, hrRest: 55, hrMax: 185, params: p)
        XCTAssertNil(s.hours[0].level)
        XCTAssertEqual(s.hours[1].level, StressModel.level(meanBPM: 75, hrRest: 55, hrMax: 185, params: p))
        XCTAssertNil(s.score, "50 rest minutes is under the 60-minute daily minimum")
        XCTAssertEqual(s.current, s.hours[1].level)
        let more = HourSlice(hour: 11, restSeconds: 30 * 60, restBPMSeconds: 75 * 30 * 60)
        XCTAssertNotNil(StressModel.summarize(slices: [long, more], windowStart: window.start, hrRest: 55, hrMax: 185,
                                              params: p).score)
    }

    // MARK: Energy

    func testEnergyStartLevels() {
        let p = ModelParameters.standard
        XCTAssertEqual(EnergyModel.startLevel(recovery: 80, sleepScore: 60, params: p)!.0, 0.65 * 80 + 0.35 * 60, accuracy: 1e-9)
        XCTAssertEqual(EnergyModel.startLevel(recovery: 80, sleepScore: nil, params: p)!.1, .recovery)
        XCTAssertEqual(EnergyModel.startLevel(recovery: nil, sleepScore: 100, params: p)!.0, 90, accuracy: 1e-9)
        XCTAssertNil(EnergyModel.startLevel(recovery: nil, sleepScore: nil, params: p))
    }

    func testEnergyDrainsChargesAndClamps() throws {
        let p = ModelParameters.standard
        let wake = at(today, 7)
        func run(_ slices: [HourSlice], loads: [Int: Double] = [:], stress: [Int: Int] = [:], start: Double = 70,
                 until hour: Int = 12) throws -> EnergySummary {
            try XCTUnwrap(EnergyModel.run(start: start, source: .recoveryAndSleep, wake: wake, asOf: at(today, hour),
                                          windowStart: window.start, slices: slices, hourlyLoad: loads,
                                          referenceLoad: 60, stressLevels: stress, params: p))
        }
        // Five quiet hours with no data: only the waking drain.
        let quiet = try run([])
        XCTAssertEqual(Double(quiet.current), 70 - 5 * p.energyAwakeDrainPerHour, accuracy: 0.5)
        XCTAssertEqual(quiet.points.count, 6)
        // A reference day's load drains the configured amount on top.
        let trained = try run([], loads: [9: 60])
        XCTAssertEqual(Double(quiet.current - trained.current), p.energyStrainDrainPerReference, accuracy: 0.5)
        // Calm rest charges; high stress drains.
        let calm = HourSlice(hour: 9, restSeconds: 3600, restBPMSeconds: 3600 * 60)
        XCTAssertGreaterThan(try run([calm], stress: [9: 10]).current, quiet.current)
        XCTAssertLessThan(try run([calm], stress: [9: 100]).current, quiet.current)
        // A nap charges.
        let nap = HourSlice(hour: 10, asleepSeconds: 3600)
        XCTAssertGreaterThan(try run([nap]).current, quiet.current)
        // Never below 0 or above 100.
        XCTAssertEqual(try run([], loads: [9: 1000]).current, 0)
        XCTAssertEqual(try run([nap], start: 100, until: 11).current, 100)
        // Not computed before waking.
        XCTAssertNil(EnergyModel.run(start: 70, source: .sleep, wake: wake, asOf: at(today, 6), windowStart: window.start,
                                     slices: [], hourlyLoad: [:], referenceLoad: 60, stressLevels: [:], params: p))
    }

    // MARK: Heart-rate recovery

    func testHeartRateRecoveryAfterWorkout() {
        let start = at(today, 18), end = at(today, 18, 45)
        var samples = hr(from: start, to: end.addingTimeInterval(-60), bpm: 150, every: 5)
        samples.append(HRSample(date: end.addingTimeInterval(-10), bpm: 172))
        samples.append(HRSample(date: end.addingTimeInterval(58), bpm: 142))
        samples.append(HRSample(date: end.addingTimeInterval(121), bpm: 120))
        let w = WorkoutSample(start: start, end: end, activityType: 37)
        let d = WorkoutRecoveryAnalyzer.analyze(workouts: [w], heartRate: samples, appleRecovery: [])[0]
        XCTAssertEqual(d.endHR, 172)
        XCTAssertEqual(d.peakHR, 172)
        XCTAssertEqual(d.drop60, 30)
        XCTAssertEqual(d.drop120, 52)
        XCTAssertEqual(d.recovery1, 30)
        let apple = [TimedValue(start: end.addingTimeInterval(60), end: end.addingTimeInterval(60), value: 27)]
        XCTAssertEqual(WorkoutRecoveryAnalyzer.analyze(workouts: [w], heartRate: samples, appleRecovery: apple)[0].recovery1, 27,
                       "Apple's value wins when Health has one")
        XCTAssertNil(WorkoutRecoveryAnalyzer.analyze(workouts: [w], heartRate: [], appleRecovery: [])[0].recovery1)
    }

    // MARK: Caffeine and hydration

    func testCaffeineAbsorptionAndHalfLife() {
        let t0 = at(today, 8)
        XCTAssertEqual(CaffeineModel.remaining(dose: 100, takenAt: t0, at: t0, halfLifeHours: 5), 0)
        let peak = CaffeineModel.remaining(dose: 100, takenAt: t0, at: t0.addingTimeInterval(45 * 60), halfLifeHours: 5)
        XCTAssertGreaterThan(peak, 94, "about 5% is eliminated during the 45-minute absorption")
        XCTAssertLessThan(peak, 100)
        let a = CaffeineModel.remaining(dose: 100, takenAt: t0, at: at(today, 10), halfLifeHours: 5)
        let b = CaffeineModel.remaining(dose: 100, takenAt: t0, at: at(today, 15), halfLifeHours: 5)
        XCTAssertEqual(b / a, 0.5, accuracy: 1e-9)
    }

    func testCutoffKeepsBedtimeCaffeineAtTheLimit() throws {
        let bed = at(today, 23)
        let morning = IntakeEntry(date: at(today, 8), kind: .caffeine, amount: 95)
        let cut = try XCTUnwrap(CaffeineModel.cutoff(existing: [morning], bedtime: bed, dose: 95, limit: 50, halfLifeHours: 5))
        let atBed = CaffeineModel.remaining([morning, IntakeEntry(date: cut, kind: .caffeine, amount: 95)], at: bed, halfLifeHours: 5)
        XCTAssertEqual(atBed, 50, accuracy: 1e-6)
        XCTAssertLessThan(cut, bed)
        let late = IntakeEntry(date: at(today, 21), kind: .caffeine, amount: 200)
        XCTAssertNil(CaffeineModel.cutoff(existing: [late], bedtime: bed, dose: 95, limit: 50, halfLifeHours: 5))
    }

    func testWaterTarget() {
        XCTAssertEqual(CaffeineModel.waterTarget(bodyMassKg: nil, mlPerKg: 35, workoutMinutes: 0), 2450)
        XCTAssertEqual(CaffeineModel.waterTarget(bodyMassKg: 80, mlPerKg: 35, workoutMinutes: 60), 3400)
        XCTAssertEqual(CaffeineModel.waterTarget(bodyMassKg: 61, mlPerKg: 35, workoutMinutes: 0), 2150)
    }

    func testIntakeSummaryInBrief() throws {
        let days = Day.range(from: today.adding(-20, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let now = at(today, 13)
        h.sync(today: today, now: now, input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        let entries = [IntakeEntry(date: at(today, 8), kind: .caffeine, amount: 95, label: "Coffee"),
                       IntakeEntry(date: at(today, 9), kind: .water, amount: 500),
                       IntakeEntry(date: at(today.adding(-1, calendar: cal), 9), kind: .water, amount: 900)]
        let b = Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male),
                       calendar: cal, asOf: now).brief(intake: entries, generatedAt: now)
        let i = try XCTUnwrap(b.intake)
        XCTAssertEqual(i.caffeineTodayMg, 95)
        XCTAssertEqual(i.waterTodayMl, 500, "yesterday's water is not today's")
        XCTAssertTrue(i.bedtimeFromHistory)
        XCTAssertEqual(i.bedtime, at(today, 23), "fixture sleep starts at 23:00 every night")
        XCTAssertGreaterThan(i.caffeineNowMg, 0)
        XCTAssertEqual(i.entriesToday.count, 2)
        XCTAssertNotNil(i.cutoff)
    }

    // MARK: Activity status

    func testStatusDaysLeaveBaselinesAndPauseLoad() {
        var records = syntheticHistory(today: today, count: 90)
        let start = today.adding(-10, calendar: cal), end = today.adding(-4, calendar: cal)
        // Make the marked days look awful: they must not move today's baseline.
        records = records.map { r in
            guard r.day >= start && r.day <= end else { return r }
            return syntheticRecord(day: r.day, lnHRV: log(30), sleepingHR: 62, workoutMinutes: 0)
        }
        let period = StatusPeriod(kind: .unwell, start: start, end: end)
        let marked = Engine(records: records, today: today, settings: UserSettings(age: 35, sex: .male), calendar: cal,
                            statusPeriods: [period])
        let unmarked = Engine(records: records, today: today, settings: UserSettings(age: 35, sex: .male), calendar: cal)
        let hrvMarked = marked.rawRecovery(at: marked.todayIndex).baselines.first { $0.kind == .hrv }!
        let hrvUnmarked = unmarked.rawRecovery(at: unmarked.todayIndex).baselines.first { $0.kind == .hrv }!
        XCTAssertEqual(hrvMarked.count, hrvUnmarked.count - 7)
        XCTAssertGreaterThan(hrvMarked.center, hrvUnmarked.center)

        let paused = marked.loadPoints.filter(\.paused)
        XCTAssertEqual(paused.count, 7)
        let before = marked.loadPoints.first { $0.day == start.adding(-1, calendar: cal) }!
        let after = marked.loadPoints.first { $0.day == end }!
        XCTAssertEqual(after.atl, before.atl)
        XCTAssertEqual(after.ctl, before.ctl)
    }

    func testTravelDoesNotPauseLoadButIsExcludedFromBaselines() {
        let records = syntheticHistory(today: today, count: 90)
        let start = today.adding(-10, calendar: cal)
        let e = Engine(records: records, today: today, settings: UserSettings(age: 35, sex: .male), calendar: cal,
                       statusPeriods: [StatusPeriod(kind: .travel, start: start, end: start.adding(2, calendar: cal))])
        XCTAssertTrue(e.loadPoints.allSatisfy { !$0.paused })
        XCTAssertEqual(e.rawRecovery(at: e.todayIndex).hrvNights, 57)
    }

    func testUnwellTodayTurnsPushOff() {
        let records = syntheticHistory(today: today, count: 90).filter { $0.day != today }
            + [syntheticRecord(day: today, lnHRV: log(55) + 0.25, sleepingHR: 47.5)]
        let settings = UserSettings(age: 35, sex: .male)
        XCTAssertEqual(Engine(records: records, today: today, settings: settings, calendar: cal).brief().plan.directive, .push)
        let b = Engine(records: records, today: today, settings: settings, calendar: cal,
                       statusPeriods: [StatusPeriod(kind: .sore, start: today)]).brief()
        XCTAssertEqual(b.plan.directive, .maintain)
        XCTAssertEqual(b.statuses, [.sore])
        XCTAssertTrue(b.plan.reasons.contains { $0.contains("sore") })
        let travel = Engine(records: records, today: today, settings: settings, calendar: cal,
                            statusPeriods: [StatusPeriod(kind: .travel, start: today)]).brief()
        XCTAssertEqual(travel.plan.directive, .push)
    }

    func testStatusPeriodCoverage() {
        let p = StatusPeriod(kind: .unwell, start: today, end: today.adding(2, calendar: cal))
        XCTAssertFalse(p.covers(today.adding(-1, calendar: cal)))
        XCTAssertTrue(p.covers(today.adding(2, calendar: cal)))
        XCTAssertFalse(p.covers(today.adding(3, calendar: cal)))
        XCTAssertTrue(StatusPeriod(kind: .sore, start: today).covers(today.adding(400, calendar: cal)))
    }

    // MARK: Pipeline, timeline, tiles

    func testBriefCarriesDaytimeSummariesFromRawData() throws {
        let days = Day.range(from: today.adding(-89, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let now = at(today, 21)
        h.sync(today: today, now: now, input: RawFixture.input(days: days, spec: RawFixture.noisySpec(seed: 11)))
        let b = h.brief(today: today, now: now)
        let stress = try XCTUnwrap(b.stress)
        XCTAssertNotNil(stress.score, "08:00-22:00 at 65 bpm gives rest-state time")
        let energy = try XCTUnwrap(b.energy)
        XCTAssertEqual(energy.startSource, .recoveryAndSleep)
        XCTAssertLessThan(energy.current, energy.start)
        XCTAssertGreaterThan(energy.drainedByStrain, 0, "the 18:00 workout drains energy")
        let hrr = try XCTUnwrap(b.heartRateRecovery)
        XCTAssertEqual(hrr.latestDay, today)
        XCTAssertEqual(b.timelines?.map(\.day), [today.adding(-1, calendar: cal), today])
    }

    func testTimelineIsChronological() throws {
        let days = Day.range(from: today.adding(-3, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let now = at(today, 22)
        h.sync(today: today, now: now, input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        let entries = [IntakeEntry(date: at(today, 8), kind: .caffeine, amount: 65, label: "Espresso"),
                       IntakeEntry(date: at(today, 12), kind: .water, amount: 250)]
        let e = Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male),
                       calendar: cal, asOf: now, statusPeriods: [StatusPeriod(kind: .travel, start: today)])
        let t = try XCTUnwrap(e.brief(journal: [today: ["Sauna"]], intake: entries, generatedAt: now).timelines?.last)
        XCTAssertEqual(t.items.map(\.kind), [.sleep, .status, .wake, .caffeine, .water, .workout, .journal],
                       "the night ending today started yesterday evening")
        XCTAssertEqual(t.items.map(\.date), t.items.map(\.date).sorted())
        XCTAssertEqual(t.items.first { $0.kind == .caffeine }?.title, "Espresso")
        XCTAssertEqual(t.items.first { $0.kind == .journal }?.detail, "Sauna")
        XCTAssertEqual(t.items.first { $0.kind == .workout }?.title, "Running")
    }

    func testDashboardTilesNeverShowAnOldDay() {
        let days = Day.range(from: today.adding(-89, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let now = at(today, 21)
        h.sync(today: today, now: now, input: RawFixture.input(days: days, spec: RawFixture.noisySpec(seed: 3)))
        let b = h.brief(today: today, now: now)
        for m in DashboardMetric.allCases {
            let tomorrow = DashboardTile.make(m, brief: b, now: at(today.adding(1, calendar: cal), 0, 5), calendar: cal)
            XCTAssertFalse(tomorrow.available, "\(m)")
            XCTAssertEqual(tomorrow.value, "–")
            XCTAssertFalse(DashboardTile.make(m, brief: nil, now: now, calendar: cal).available)
        }
        // The fixture has no heart rate right after workouts, so there is no recovery value.
        XCTAssertEqual(DashboardTile.make(.hrRecovery, brief: b, now: now, calendar: cal).caption, "No post-workout HR")
        for m: DashboardMetric in [.recovery, .strain, .energy, .stress, .sleep, .hrv, .sleepingHR] {
            let tile = DashboardTile.make(m, brief: b, now: now, calendar: cal)
            XCTAssertTrue(tile.available, "\(m)")
            if let f = tile.fraction { XCTAssertTrue((0...1).contains(f), "\(m) \(f)") }
        }
    }

    func testLifestyleSettingsDecodeTolerantly() throws {
        let partial = Data(#"{"caffeineHalfLifeHours":6,"pinnedMetrics":["energy","fromTheFuture","water"],"checkIns":{"weeklyReview":false}}"#.utf8)
        let s = try JSONDecoder().decode(LifestyleSettings.self, from: partial)
        XCTAssertEqual(s.caffeineHalfLifeHours, 6)
        XCTAssertEqual(s.bedtimeCaffeineLimitMg, 50)
        XCTAssertEqual(s.pinnedMetrics, [.energy, .water])
        XCTAssertFalse(s.checkIns.weeklyReview)
        XCTAssertTrue(s.checkIns.morningSummary)
        let roundTrip = try JSONDecoder().decode(LifestyleSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundTrip, s)
    }

    func testOldBriefWithoutNewFieldsStillDecodes() throws {
        let days = Day.range(from: today.adding(-20, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 12), input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        var old = h.brief(today: today, now: at(today, 12))
        old.strain = nil; old.stress = nil; old.energy = nil; old.intake = nil
        old.heartRateRecovery = nil; old.statuses = nil; old.timelines = nil
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        XCTAssertNil(json["strain"])
        let decoded = try JSONDecoder().decode(DailyBrief.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, old)
    }
}
