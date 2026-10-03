import XCTest
@testable import MarginCore

/// Phase 2 failure modes, numbered as in the device-validation brief. Each test
/// drives raw HealthKit-shaped samples through the production planner, builder,
/// engine and complication-state code.
final class FailureModeTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var noon: Date { at(today, 12) }

    func days(_ n: Int, endingOn end: Day? = nil) -> [Day] {
        let e = end ?? today
        return Day.range(from: e.adding(-(n - 1), calendar: testCalendar), to: e, calendar: testCalendar)
    }

    func harness(_ input: RawDayInput, now: Date? = nil) -> PipelineHarness {
        var h = PipelineHarness()
        h.sync(today: today, now: now ?? noon, input: input)
        return h
    }

    // 1
    func testNoHealthKitData() {
        let h = harness(RawDayInput())
        XCTAssertEqual(h.records.count, SyncParameters.standard.historyDays)
        XCTAssertTrue(h.records.values.allSatisfy(\.isEmpty))
        let b = h.brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.status, .calibrating)
        XCTAssertNil(b.recovery.score)
        XCTAssertEqual(b.plan.directive, .calibrating)
        XCTAssertNil(b.plan.targetHigh)
        XCTAssertEqual(b.recovery.calibration.hrvNights, 0)
        XCTAssertTrue(b.audit.inputs.allSatisfy { $0.daysWithDataInWindow == 0 })
        let w = ComplicationState.make(brief: b, now: noon, calendar: testCalendar)
        XCTAssertEqual(w.kind, .calibrating)
        XCTAssertEqual(w.headline, "CALIBRATING 0/14")
    }

    // 2a
    func testPartialPermissionsHRVDeniedWithholdsScore() {
        let input = RawFixture.input(days: days(90)) { _ in NightSpec(hrvMs: nil) }
        let b = harness(input).brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.status, .hrvUnavailable)
        XCTAssertNil(b.recovery.score, "no normal-looking score from heart rate alone")
        XCTAssertEqual(b.plan.directive, .noData)
        XCTAssertTrue(b.recovery.statusDetail.contains("Heart Rate Variability"))
        XCTAssertEqual(b.audit.input(.hrv)?.daysWithDataInWindow, 0)
        XCTAssertEqual(b.audit.input(.heartRate)?.daysWithDataInWindow, 60)
        let w = ComplicationState.make(brief: b, now: noon, calendar: testCalendar)
        XCTAssertEqual(w.kind, .unavailable)
        XCTAssertEqual(w.detail, "HRV unavailable")
    }

    // 2b
    func testPartialPermissionsOptionalInputsDeniedStillScoresAndReportsGap() {
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 3)).withoutOptionalInputs()
        let b = harness(input).brief(today: today, now: noon)
        XCTAssertTrue(b.recovery.status.hasScore)
        XCTAssertEqual(Set(b.recovery.components.map(\.kind)), [.hrv, .restingHR, .sleep])
        XCTAssertEqual(b.audit.input(.respiratoryRate)?.daysWithDataLast7, 0)
        XCTAssertEqual(b.audit.input(.wristTemperature)?.daysWithDataLast7, 0)
    }

    // 3
    func testExactlyEnoughCalibrationDays() {
        let input = RawFixture.input(days: days(15), spec: RawFixture.noisySpec(seed: 5))
        let b = harness(input).brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.calibration.hrvNights, 14)
        XCTAssertEqual(b.recovery.calibration.stage, .provisionalScale)
        XCTAssertEqual(b.recovery.status, .provisional)
        XCTAssertNotNil(b.recovery.score)
        XCTAssertNotEqual(b.plan.directive, .push, "provisional scale never produces Push")
    }

    // 4
    func testOneDayBelowCalibration() {
        let input = RawFixture.input(days: days(14), spec: RawFixture.noisySpec(seed: 5))
        let b = harness(input).brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.calibration.hrvNights, 13)
        XCTAssertEqual(b.recovery.status, .calibrating)
        XCTAssertNil(b.recovery.score)
        XCTAssertEqual(b.recovery.statusDetail, "Calibrating: 13 of 14 nights with HRV.")
    }

    // 5
    func testMissingHRVButSleepingHRPresentIsDegradedAndBlocksPush() {
        let override: [Day: NightSpec?] = [today: NightSpec(hrvMs: nil, sleepingHR: 45)]
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 9, override: override))
        let b = harness(input).brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.status, .degraded)
        XCTAssertEqual(b.recovery.missingInputs, [.hrv])
        XCTAssertNotNil(b.recovery.score)
        XCTAssertNotEqual(b.plan.directive, .push)
        if (b.recovery.score ?? 0) >= 67 {
            XCTAssertTrue(b.plan.trace.contains { $0.rule == "Push needs full inputs and calibrated scale" && !$0.passed })
        }
    }

    // 6
    func testMissingSleepingHRButHRVPresentIsDegradedAndBlocksPush() {
        let override: [Day: NightSpec?] = [today: NightSpec(hrvMs: 80, sleepingHR: nil)]
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 9, override: override))
        let b = harness(input).brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.status, .degraded)
        XCTAssertEqual(b.recovery.missingInputs, [.restingHR])
        XCTAssertGreaterThanOrEqual(b.recovery.score ?? 0, 67, "high HRV night")
        XCTAssertEqual(b.plan.directive, .maintain)
        XCTAssertTrue(b.plan.trace.contains { $0.rule == "Push needs full inputs and calibrated scale" && !$0.passed })
    }

    // 7
    func testDuplicateSamplesAreRemovedAndCounted() {
        let ds = days(3)
        let clean = RawFixture.input(days: ds) { _ in NightSpec() }
        var doubled = clean
        doubled.hrv += clean.hrv
        doubled.heartRate += clean.heartRate
        doubled.sleep += clean.sleep
        doubled.workouts += clean.workouts
        let w = DayWindows.nominal(for: today, calendar: testCalendar)
        let a = DayRecordBuilder.build(day: today, windows: w, input: clean, asOf: noon, builtAt: noon)
        let b = DayRecordBuilder.build(day: today, windows: w, input: doubled, asOf: noon, builtAt: noon)
        XCTAssertEqual(a.lnHRV, b.lnHRV)
        XCTAssertEqual(a.sleep, b.sleep)
        XCTAssertEqual(a.sleepingHR, b.sleepingHR)
        XCTAssertEqual(a.activity, b.activity)
        XCTAssertEqual(a.workouts, b.workouts)
        XCTAssertEqual(a.sourceFingerprint, b.sourceFingerprint, "duplicates do not trigger rebuilds")
        XCTAssertEqual(b.ingestion[.hrv].duplicates, a.ingestion[.hrv].accepted)
        XCTAssertEqual(b.ingestion[.workouts].duplicates, 1)
        XCTAssertGreaterThan(b.ingestion[.heartRate].duplicates, 0)
    }

    // 8
    func testLateArrivingSamplesAreReconciled() {
        let ds = days(90)
        let spec = RawFixture.noisySpec(seed: 11)
        // At 06:00 HealthKit has not yet delivered last night's data.
        let early = RawFixture.input(days: ds) { $0 == self.today ? NightSpec(hrvMs: nil, sleepingHR: nil, asleepHours: nil) : spec($0) }
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 6), input: early)
        XCTAssertFalse(h.brief(today: today, now: at(today, 6)).recovery.status.hasScore)

        // Later the night arrives, plus a correction for a day well outside the reconcile window.
        let old = today.adding(-20, calendar: testCalendar)
        var late = RawFixture.input(days: ds, spec: spec)
        late.hrv.append(TimedValue(start: at(old, 2, 30), end: at(old, 2, 31), value: 70))
        let plan = h.sync(today: today, now: noon, input: late)
        XCTAssertEqual(plan.items.first { $0.day == today }?.reason, .recent)
        XCTAssertEqual(plan.items.first { $0.day == old }?.reason, .sourceChanged)
        XCTAssertTrue(h.brief(today: today, now: noon).recovery.status.hasScore)
    }

    // 9
    func testCorrectedAndDeletedSamplesTriggerRebuild() {
        let ds = days(90)
        let input = RawFixture.input(days: ds, spec: RawFixture.noisySpec(seed: 13))
        var h = PipelineHarness()
        h.sync(today: today, now: noon, input: input)
        let target = today.adding(-10, calendar: testCalendar)
        let before = h.records[target]!

        // Deletion: remove that night's HRV samples.
        var deleted = input
        let night = before.windows!.night
        deleted.hrv.removeAll { night.contains($0.start) }
        let plan = h.sync(today: today, now: noon.addingTimeInterval(60), input: deleted)
        let item = plan.items.first { $0.day == target }
        XCTAssertEqual(item?.reason, .sourceChanged)
        XCTAssertEqual(item?.replaces, true)
        XCTAssertNil(h.records[target]?.lnHRV)
        XCTAssertEqual(plan.count(.sourceChanged), 1, "only the affected day is rebuilt")

        // Correction: same sample count, different value.
        var corrected = deleted
        let t = before.sleep!.mainOnset.addingTimeInterval(2 * 3600)
        corrected.hrv.append(TimedValue(start: t, end: t.addingTimeInterval(60), value: 40))
        h.sync(today: today, now: noon.addingTimeInterval(120), input: corrected)
        XCTAssertEqual(h.records[target]!.lnHRV!, log(40), accuracy: 1e-12)

        // Permission revoked: HealthKit now returns no HRV at all.
        var revoked = corrected
        revoked.hrv = []
        h.sync(today: today, now: noon.addingTimeInterval(180), input: revoked)
        XCTAssertEqual(h.brief(today: today, now: noon).recovery.status, .hrvUnavailable)
    }

    // 10
    func testDayCrossingMidnight() {
        let d1 = today.adding(-1, calendar: testCalendar)
        var input = RawDayInput()
        input.sleep = [SleepSegment(start: at(d1, 22, 30), end: at(today, 6, 30), stage: .core, sourcePriority: 2)]
        var t = at(d1, 23, 50)
        while t < at(today, 0, 10) {
            input.heartRate.append(HRSample(date: t, bpm: 150))
            t = t.addingTimeInterval(5)
        }
        var h = PipelineHarness()
        h.sync(today: today, now: noon, input: input)
        XCTAssertEqual(h.records[today]?.sleep?.asleep, 8 * 3600, "sleep goes to the wake day")
        XCTAssertNil(h.records[d1]?.sleep)
        XCTAssertEqual(h.records[d1]!.activity.seconds[150], 600, accuracy: 1e-9)
        // 120 samples after midnight; the last one holds for the 300 s gap cap.
        XCTAssertEqual(h.records[today]!.activity.seconds[150], 119 * 5 + 300, accuracy: 1e-9)
    }

    // 11
    func testTimeZoneChangeLeavesNoOverlapOrGap() {
        let d1 = today.adding(-1, calendar: testCalendar)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // Continuous HR across both days.
        var input = RawDayInput()
        var t = at(d1, 0)
        while t < at(today, 23) {
            input.heartRate.append(HRSample(date: t, bpm: 70))
            t = t.addingTimeInterval(60)
        }
        // Day 1 built in New York, then the user flies to Tokyo.
        let w1 = DayWindows.nominal(for: d1, calendar: testCalendar)
        var records: [Day: DayRecord] = [d1: DayRecordBuilder.build(day: d1, windows: w1, input: input, asOf: noon, builtAt: noon)]
        let plan = SyncPlanner.plan(existing: records, today: today, calendar: tokyo, now: noon, mode: .foreground,
                                    currentFingerprints: nil)
        let w2 = plan.items.first { $0.day == today }!.windows
        XCTAssertEqual(w2.activity.start, w1.activity.end, "no overlap and no gap")
        XCTAssertEqual(w2.night.start, w1.night.end)
        XCTAssertEqual(w2.timeZoneID, "Asia/Tokyo")
        records[today] = DayRecordBuilder.build(day: today, windows: w2, input: input, asOf: noon, builtAt: noon)
        let nominal2 = DayWindows.nominal(for: today, calendar: tokyo)
        XCTAssertGreaterThan(w1.activity.end, nominal2.activity.start, "nominal Tokyo window would have overlapped")
        // Every minute of HR counted exactly once across the two days.
        let total = records[d1]!.activity.totalSeconds + records[today]!.activity.totalSeconds
        let covered = min(w2.activity.end, at(today, 23)).timeIntervalSince(w1.activity.start)
        XCTAssertEqual(total, covered, accuracy: 60)
        // Engine midpoints use stored windows, not the current zone.
        XCTAssertEqual(Engine(records: Array(records.values), today: today, settings: UserSettings(),
                              calendar: tokyo).windows(at: 0), w1)
    }

    // 11b: westward travel leaves a gap in nominal windows; chaining closes it.
    func testWestwardTimeZoneChangeClosesGap() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let d1 = today.adding(-1, calendar: testCalendar)
        let w1 = DayWindows.nominal(for: d1, calendar: tokyo)
        let records = [d1: DayRecord(day: d1, windows: w1, builtAt: noon)]
        let plan = SyncPlanner.plan(existing: records, today: today, calendar: testCalendar, now: noon,
                                    mode: .foreground, currentFingerprints: nil)
        let w2 = plan.items.first { $0.day == today }!.windows
        XCTAssertEqual(w2.activity.start, w1.activity.end)
        XCTAssertLessThan(w1.activity.end, DayWindows.nominal(for: today, calendar: testCalendar).activity.start)
        // A day backfilled before an existing record is clipped so it cannot overlap it.
        let before = plan.items.first { $0.day == d1.adding(-1, calendar: testCalendar) }!.windows
        XCTAssertEqual(before.activity.end, w1.activity.start)
        XCTAssertEqual(before.night.end, w1.night.start)
    }

    // 12
    func testDSTBoundariesKeepContinuousCoverage() {
        for anchor in [Day(year: 2026, month: 3, day: 8), Day(year: 2026, month: 11, day: 1)] {
            let span = Day.range(from: anchor.adding(-1, calendar: testCalendar),
                                 to: anchor.adding(1, calendar: testCalendar), calendar: testCalendar)
            var input = RawDayInput()
            var t = at(span[0], 0)
            let end = at(span[2], 0).addingTimeInterval(24 * 3600)
            while t < end {
                input.heartRate.append(HRSample(date: t, bpm: 70))
                t = t.addingTimeInterval(60)
            }
            var h = PipelineHarness()
            h.sync(today: span[2], now: end.addingTimeInterval(3600), input: input)
            let r = h.records[anchor]!
            XCTAssertEqual(r.windows!.activity.start, h.records[span[0]]!.windows!.activity.end)
            XCTAssertEqual(r.windows!.activity.end, h.records[span[2]]!.windows!.activity.start)
            let expected = anchor.month == 3 ? 23.0 : 25.0
            XCTAssertEqual(r.coverageHours, expected, accuracy: 1e-9, "\(anchor)")
        }
    }

    // 13
    func testWorkoutSpanningMidnight() {
        let d1 = today.adding(-1, calendar: testCalendar)
        var input = RawDayInput()
        let start = at(d1, 23, 30), end = at(today, 0, 45)
        input.workouts = [WorkoutSample(start: start, end: end, activityType: 37)]
        var t = start
        while t < end {
            input.heartRate.append(HRSample(date: t, bpm: 140))
            t = t.addingTimeInterval(5)
        }
        var h = PipelineHarness()
        h.sync(today: today, now: noon, input: input)
        XCTAssertEqual(h.records[d1]!.workouts.started, 1)
        XCTAssertEqual(h.records[d1]!.workouts.minutes, 30, accuracy: 1e-9)
        XCTAssertEqual(h.records[today]!.workouts.started, 0, "counted once, on the start day")
        XCTAssertEqual(h.records[today]!.workouts.minutes, 45, accuracy: 1e-9)
        XCTAssertEqual(h.records[d1]!.workouts.heartRateCoverage!, 1, accuracy: 1e-9)
        XCTAssertEqual(h.records[today]!.workouts.heartRateCoverage!, 1, accuracy: 0.01)
    }

    // 14
    func testMultipleWorkoutsInOneDay() {
        var input = RawDayInput()
        for (h0, minutes) in [(7, 30.0), (12, 20.0), (18, 60.0)] {
            input.workouts.append(WorkoutSample(start: at(today, h0), end: at(today, h0).addingTimeInterval(minutes * 60),
                                                activityType: 37))
        }
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 20), input: input)
        let w = h.records[today]!.workouts
        XCTAssertEqual(w.started, 3)
        XCTAssertEqual(w.minutes, 110, accuracy: 1e-9)
        XCTAssertEqual(w.latestEnd, at(today, 19))
        XCTAssertEqual(w.heartRateCoverage, 0, "no HR during workouts is reported, not hidden")
        XCTAssertEqual(h.brief(today: today, now: at(today, 20)).audit.workoutsLast7, 3)
    }

    // 15
    func testZeroDurationAndMalformedWorkoutsAreRejected() {
        var input = RawDayInput()
        input.workouts = [
            WorkoutSample(start: at(today, 9), end: at(today, 9), activityType: 37),
            WorkoutSample(start: at(today, 10), end: at(today, 9, 30), activityType: 37),
            WorkoutSample(start: at(today, 1), end: at(today, 1).addingTimeInterval(30 * 3600), activityType: 37),
        ]
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 20), input: input)
        let r = h.records[today]!
        XCTAssertEqual(r.workouts.started, 0)
        XCTAssertEqual(r.ingestion[.workouts].implausible, 3)
        XCTAssertTrue(DayQuality.notes(for: r).contains("Rejected samples: 0 duplicate, 3 implausible, 0 future-dated"))
    }

    // 16
    func testFutureDatedSamplesAreExcluded() {
        let morning = at(today, 7)
        var input = RawFixture.input(days: [today]) { _ in NightSpec(workoutMinutes: 0, daytimeHR: false) }
        input.hrv.append(TimedValue(start: at(today, 9), end: at(today, 9, 1), value: 300))
        input.heartRate.append(HRSample(date: at(today, 15), bpm: 180))
        let r = DayRecordBuilder.build(day: today, windows: .nominal(for: today, calendar: testCalendar),
                                       input: input, asOf: morning, builtAt: morning)
        XCTAssertEqual(r.ingestion[.hrv].future, 1)
        XCTAssertEqual(r.ingestion[.heartRate].future, 1)
        XCTAssertEqual(r.lnHRV!, log(55), accuracy: 1e-12)
        XCTAssertEqual(r.activity.seconds[180], 0)
    }

    // 17
    func testLongPeriodWithoutOpeningTheApp() {
        let lastOpened = today.adding(-10, calendar: testCalendar)
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 17))
        var h = PipelineHarness()
        h.sync(today: lastOpened, now: at(lastOpened, 12), input: input)
        let staleBrief = h.brief(today: lastOpened, now: at(lastOpened, 12))

        // Widget after 10 days: never shows the old score as today's.
        let w = ComplicationState.make(brief: staleBrief, now: noon, calendar: testCalendar)
        XCTAssertEqual(w.kind, .stale)
        XCTAssertEqual(w.scoreText, "–")

        // Background task: only the most recent days, the rest deferred.
        let bg = SyncPlanner.plan(existing: h.records, today: today, calendar: testCalendar, now: noon,
                                  mode: .background, currentFingerprints: nil)
        XCTAssertEqual(bg.items.map(\.day), [today, today.adding(-1, calendar: testCalendar)])
        XCTAssertEqual(bg.deferred.filter { h.records[$0] == nil }.count, 8, "8 never-built days wait for the foreground")
        XCTAssertTrue(bg.deferred.allSatisfy { h.records[$0] == nil || h.records[$0]!.isEmpty },
                      "everything else deferred is an empty day due for a retry")

        // Opening the app fills the whole gap.
        let plan = h.sync(today: today, now: noon, input: input)
        XCTAssertEqual(plan.count(.missing), 10)
        XCTAssertTrue(h.brief(today: today, now: noon).recovery.status.hasScore)
    }

    // 18
    func testAppRestartRestoresIdenticalBrief() throws {
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 19))
        let h = harness(input)
        let before = h.brief(today: today, now: noon)
        let data = try RecordCacheFile(records: h.records, savedAt: noon, retentionDays: 400).encoded()
        guard case .ok(let restored, let savedAt) = RecordCacheFile.decode(data) else { return XCTFail("decode") }
        XCTAssertEqual(savedAt, noon)
        var h2 = PipelineHarness()
        h2.records = Dictionary(uniqueKeysWithValues: restored.map { ($0.day, $0) })
        XCTAssertEqual(h2.brief(today: today, now: noon), before)
    }

    // 19
    func testRebootReconstructsPersistedStateAndRejectsBadCaches() throws {
        let input = RawFixture.input(days: days(30), spec: RawFixture.noisySpec(seed: 23))
        let h = harness(input)
        let data = try RecordCacheFile(records: h.records, savedAt: noon, retentionDays: 400).encoded()
        guard case .ok(let restored, _) = RecordCacheFile.decode(data) else { return XCTFail("decode") }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: restored.map { ($0.day, $0) }), h.records)

        let oldSchema = Data(#"{"schema":1,"records":[]}"#.utf8)
        XCTAssertEqual(RecordCacheFile.decode(oldSchema), .schemaMismatch(found: 1, expected: DayRecord.schemaVersion))
        if case .corrupt = RecordCacheFile.decode(Data("garbage".utf8)) {} else { XCTFail("garbage must be reported as corrupt") }
        var truncated = data
        truncated.removeLast(data.count / 2)
        if case .corrupt = RecordCacheFile.decode(truncated) {} else { XCTFail("truncated file must be reported as corrupt") }

        // A restored cache is reconciled, not trusted blindly: recent days are re-read.
        var h2 = PipelineHarness()
        h2.records = h.records
        let plan = h2.sync(today: today, now: noon.addingTimeInterval(3600), input: input)
        XCTAssertEqual(plan.count(.recent), SyncParameters.standard.reconcileDays)
        XCTAssertEqual(plan.count(.missing), 0)
        XCTAssertEqual(plan.count(.sourceChanged), 0)
    }

    // 20
    func testScoreDeterminismAfterReloadIsByteIdentical() throws {
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 29))
        let h = harness(input)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let a = try enc.encode(h.brief(today: today, now: noon))
        let data = try RecordCacheFile(records: h.records, savedAt: noon, retentionDays: 400).encoded()
        guard case .ok(let restored, _) = RecordCacheFile.decode(data) else { return XCTFail("decode") }
        for order in [restored, restored.reversed(), restored.shuffledDeterministically()] {
            let e = Engine(records: order, today: today, settings: UserSettings(age: 35, sex: .male),
                           calendar: testCalendar, asOf: noon)
            XCTAssertEqual(try enc.encode(e.brief(generatedAt: noon, dataSyncedAt: noon)), a)
        }
    }

    // 21
    func testWidgetStateWhenScoreUnavailable() {
        let override: [Day: NightSpec?] = [today: NightSpec(hrvMs: nil, sleepingHR: nil, asleepHours: nil)]
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 31, override: override))
        let b = harness(input).brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.status, .noOvernightData)
        let w = ComplicationState.make(brief: b, now: noon, calendar: testCalendar)
        XCTAssertEqual(w.kind, .unavailable)
        XCTAssertEqual(w.scoreText, "–")
        XCTAssertEqual(w.gaugeFraction, 0)
        XCTAssertEqual(w.detail, "No overnight data")
        XCTAssertFalse(w.inline.contains("PUSH") || w.inline.contains("RECOVER"))
    }

    // 22
    func testWidgetStateWhileCalibrating() {
        let input = RawFixture.input(days: days(10), spec: RawFixture.noisySpec(seed: 37))
        let b = harness(input).brief(today: today, now: noon)
        let w = ComplicationState.make(brief: b, now: noon, calendar: testCalendar)
        XCTAssertEqual(w.kind, .calibrating)
        XCTAssertEqual(w.headline, "CALIBRATING 9/14")
        XCTAssertEqual(w.gaugeFraction, 9.0 / 14, accuracy: 1e-12)
        XCTAssertEqual(w.directive, .calibrating)
    }

    // 23
    func testWidgetStateAfterScoreChange() {
        let low = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 41, override: [today: NightSpec(hrvMs: 30, sleepingHR: 58)]))
        let high = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 41, override: [today: NightSpec(hrvMs: 80, sleepingHR: 46)]))
        var h = PipelineHarness()
        h.sync(today: today, now: noon, input: low)
        let w1 = ComplicationState.make(brief: h.brief(today: today, now: noon), now: noon, calendar: testCalendar)
        h.sync(today: today, now: noon.addingTimeInterval(600), input: high)
        let w2 = ComplicationState.make(brief: h.brief(today: today, now: noon.addingTimeInterval(600)),
                                        now: noon.addingTimeInterval(600), calendar: testCalendar)
        XCTAssertEqual(w1.kind, .score)
        XCTAssertEqual(w2.kind, .score)
        XCTAssertEqual(w1.band, .depleted)
        XCTAssertEqual(w2.band, .primed)
        XCTAssertNotEqual(w1.scoreText, w2.scoreText)
        XCTAssertEqual(w1.headline, "REC \(w1.scoreText)")
        XCTAssertNotEqual(w1.directive, w2.directive)
    }

    // 24
    func testStalePersistedScoreVersusNewerHealthKitData() {
        let spec = RawFixture.noisySpec(seed: 43)
        let ds = days(90)
        // 07:00: sleep not yet written -> no score is persisted, not a guessed one.
        let partial = RawFixture.input(days: ds) { $0 == self.today ? NightSpec(hrvMs: nil, sleepingHR: nil, asleepHours: nil) : spec($0) }
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 7), input: partial)
        let persisted = h.brief(today: today, now: at(today, 7))
        XCTAssertFalse(persisted.recovery.status.hasScore)

        // Newer data arrives; the next sync rebuilds today and replaces the brief.
        let full = RawFixture.input(days: ds, spec: spec)
        let plan = h.sync(today: today, now: noon, input: full)
        XCTAssertEqual(plan.items.first { $0.day == today }?.reason, .recent)
        let fresh = h.brief(today: today, now: noon)
        XCTAssertTrue(fresh.recovery.status.hasScore)
        XCTAssertEqual(ComplicationState.make(brief: fresh, now: noon, calendar: testCalendar).kind, .score)

        // A same-day brief whose last sync is old is flagged, not silently trusted.
        var old = fresh
        old.dataSyncedAt = at(today, 0, 30)
        old.recovery.flags = []
        old.recovery.status = .scored
        let w = ComplicationState.make(brief: old, now: at(today, 23), calendar: testCalendar)
        XCTAssertTrue(w.footnote.hasPrefix("Synced 00:30"))
        XCTAssertTrue(w.footnoteIsWarning)
    }

    // Night in progress: no score until the overnight window closes.
    func testNightInProgressWithholdsScoreUntilWake() {
        let input = RawFixture.input(days: days(90), spec: RawFixture.noisySpec(seed: 47))
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 3), input: input)
        let atThree = h.brief(today: today, now: at(today, 3))
        XCTAssertEqual(atThree.recovery.status, .nightInProgress)
        XCTAssertNil(atThree.recovery.score)
        XCTAssertEqual(atThree.plan.directive, .pending)
        XCTAssertEqual(ComplicationState.make(brief: atThree, now: at(today, 3), calendar: testCalendar).kind, .pending)
        let wake = h.records[today]!.sleep!.mainWake
        XCTAssertEqual(h.brief(today: today, now: wake.addingTimeInterval(29 * 60)).recovery.status, .nightInProgress)
        XCTAssertTrue(h.brief(today: today, now: wake.addingTimeInterval(31 * 60)).recovery.status.hasScore)
    }
}

extension RawDayInput {
    func withoutOptionalInputs() -> RawDayInput {
        var c = self
        c.respiratoryRate = []
        c.wristTemperature = []
        return c
    }
}

extension Array {
    /// Fixed permutation (no RNG) so the test is reproducible.
    func shuffledDeterministically() -> [Element] {
        guard count > 2 else { return self }
        var out: [Element] = []
        var i = 0
        var used = Set<Int>()
        while out.count < count {
            i = (i + 7) % count
            while used.contains(i) { i = (i + 1) % count }
            used.insert(i)
            out.append(self[i])
        }
        return out
    }
}
