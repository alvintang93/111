import XCTest
@testable import MarginCore

final class ObservabilityTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var noon: Date { at(today, 12) }

    func scoredHarness(seed: UInt64 = 51, override: [Day: NightSpec?] = [:]) -> PipelineHarness {
        let ds = Day.range(from: today.adding(-89, calendar: testCalendar), to: today, calendar: testCalendar)
        var h = PipelineHarness()
        h.sync(today: today, now: noon, input: RawFixture.input(days: ds, spec: RawFixture.noisySpec(seed: seed, override: override)))
        return h
    }

    // MARK: Fingerprint

    func testFNV1aMatchesReferenceVectors() {
        // Reference values computed with an independent Python implementation
        // (which reproduces the published FNV-1a 64 vector for "a").
        var a = FNV1a()
        XCTAssertEqual(a.value, 0xcbf2_9ce4_8422_2325)
        a.add(UInt64(0x0102_0304_0506_0708))
        XCTAssertEqual(a.value, 0x0c6d_4496_e178_59d5)
        var b = FNV1a()
        b.add(UInt64(1))
        b.add(UInt64(2))
        XCTAssertEqual(b.value, 0x7717_9803_63c8_e066)
        XCTAssertEqual(b.hex, "7717980363c8e066")
    }

    func testFingerprintIgnoresSampleOrderAndOutOfWindowData() {
        let ds = Day.range(from: today.adding(-2, calendar: testCalendar), to: today, calendar: testCalendar)
        let input = RawFixture.input(days: ds) { _ in NightSpec() }
        var shuffled = input
        shuffled.hrv.reverse()
        shuffled.sleep.reverse()
        let w = DayWindows.nominal(for: today, calendar: testCalendar)
        XCTAssertEqual(SourceFingerprint.compute(windows: w, input: input, asOf: noon),
                       SourceFingerprint.compute(windows: w, input: shuffled, asOf: noon))
        var far = input
        far.hrv.append(TimedValue(start: at(today.adding(-30, calendar: testCalendar), 3), end: at(today.adding(-30, calendar: testCalendar), 3, 1), value: 60))
        XCTAssertEqual(SourceFingerprint.compute(windows: w, input: input, asOf: noon),
                       SourceFingerprint.compute(windows: w, input: far, asOf: noon))
    }

    // MARK: Plausibility

    func testImplausibleValuesAreRejectedNotClamped() {
        var input = RawFixture.input(days: [today]) { _ in NightSpec(workoutMinutes: 0, daytimeHR: false) }
        input.heartRate.append(HRSample(date: at(today, 2), bpm: 300))
        input.heartRate.append(HRSample(date: at(today, 2, 1), bpm: .nan))
        input.hrv.append(TimedValue(start: at(today, 2), end: at(today, 2, 1), value: 0))
        input.respiratoryRate.append(TimedValue(start: at(today, 2), end: at(today, 2, 1), value: 90))
        input.wristTemperature.append(TimedValue(start: at(today, 2), end: at(today, 2, 1), value: .infinity))
        input.sleep.append(SleepSegment(start: at(today, 3), end: at(today, 3), stage: .deep, sourcePriority: 2))
        let r = DayRecordBuilder.build(day: today, windows: .nominal(for: today, calendar: testCalendar),
                                       input: input, asOf: noon, builtAt: noon)
        XCTAssertEqual(r.ingestion[.heartRate].implausible, 2)
        XCTAssertEqual(r.ingestion[.hrv].implausible, 1)
        XCTAssertEqual(r.ingestion[.respiratoryRate].implausible, 1)
        XCTAssertEqual(r.ingestion[.wristTemperature].implausible, 1)
        XCTAssertEqual(r.ingestion[.sleep].implausible, 1)
        XCTAssertEqual(r.activity.seconds[HeartRateHistogram.maxBPM], 0, "300 bpm is not clamped into the top bin")
        XCTAssertEqual(r.lnHRV!, log(55), accuracy: 1e-12)
        XCTAssertEqual(r.respiratoryRate!, 14, accuracy: 1e-12)
    }

    // MARK: Decision trace and distribution

    func testTraceExplainsEveryRecommendation() {
        let h = scoredHarness()
        let b = h.brief(today: today, now: noon)
        let trace = b.plan.trace
        XCTAssertEqual(trace.first?.rule, "Score available")
        XCTAssertTrue(trace.first!.passed)
        XCTAssertEqual(Set(trace.map(\.rule)).count, trace.count, "rules are unique")
        switch b.plan.directive {
        case .push:
            XCTAssertTrue(trace.suffix(5).allSatisfy(\.passed), "all Push gates passed")
        case .recover:
            XCTAssertTrue(trace.last!.passed)
        case .maintain:
            XCTAssertFalse(trace.contains { $0.rule.hasSuffix("-> Recover") && $0.passed })
        default:
            XCTFail("unexpected directive \(b.plan.directive)")
        }
    }

    func testTraceForWithheldScoreStopsAtAvailability() {
        let h = scoredHarness(override: [today: NightSpec(hrvMs: nil, sleepingHR: nil, asleepHours: nil)])
        let b = h.brief(today: today, now: noon)
        XCTAssertEqual(b.plan.trace.count, 1)
        XCTAssertFalse(b.plan.trace[0].passed)
        XCTAssertTrue(b.plan.trace[0].detail.hasPrefix("noOvernightData"))
    }

    func testDistributionMatchesPerDayRecomputation() {
        let h = scoredHarness()
        let b = h.brief(today: today, now: noon)
        let d = b.audit.distribution
        XCTAssertEqual(d.days, 60)
        XCTAssertEqual(d.directives.reduce(0) { $0 + $1.count }, d.days)
        XCTAssertEqual(d.statuses.reduce(0) { $0 + $1.count }, d.days)
        XCTAssertEqual(d.scoreHistogram.reduce(0, +), d.statuses.filter {
            ScoreStatus(rawValue: $0.key)!.hasScore
        }.reduce(0) { $0 + $1.count })
        // Recompute independently through the public per-day API and compare counts.
        let engine = Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male),
                            calendar: testCalendar, asOf: noon)
        var push = 0
        for k in (engine.days.count - 60)..<engine.days.count {
            let r = engine.recovery(at: k)
            if engine.directive(for: r).0 == .push { push += 1 }
        }
        XCTAssertEqual(d.count(.push), push)
        XCTAssertEqual(b.audit.thresholds.recoverScore, 15)
        XCTAssertEqual(b.audit.thresholds.weights.map(\.weight).reduce(0, +), 1, accuracy: 1e-12)
    }

    func testAuditReportsCalibrationCountsAndSources() {
        let b = scoredHarness().brief(today: today, now: noon)
        XCTAssertEqual(b.recovery.calibration.hrvNights, 60)
        XCTAssertEqual(b.recovery.calibration.sleepingHRNights, 60)
        XCTAssertEqual(b.recovery.calibration.stage, .calibrated)
        XCTAssertEqual(b.audit.recentTimeZones, ["America/New_York"])
        XCTAssertTrue(b.audit.hrRestSource.hasPrefix("Apple resting HR"))
        XCTAssertEqual(b.audit.hrMaxSource, "208 - 0.7 x age (35)")
        // Today's 18:01 fixture workout is after the noon build time, so it is future-filtered.
        XCTAssertEqual(b.audit.workoutsLast7, 6)
        XCTAssertEqual(b.audit.workoutHRCoverageLast7!, 1, accuracy: 0.01)
        XCTAssertNotNil(b.audit.input(.sleep)?.latestSample)
        XCTAssertEqual(Set(b.audit.baselines.map(\.kind)), [.hrv, .restingHR, .respiratoryRate, .wristTemperature])
    }

    // MARK: Logs

    func testEventLogKeepsMostRecentWithinCapacity() {
        var log = EventLog(capacity: 3)
        for k in 0..<5 {
            log.append(PipelineEvent(at: Date(timeIntervalSince1970: Double(k)), stage: k == 3 ? .persist : .query,
                                     level: k == 3 ? .error : .info, message: "e\(k)"))
        }
        XCTAssertEqual(log.events.map(\.message), ["e2", "e3", "e4"])
        XCTAssertEqual(log.latestError()?.message, "e3")
        XCTAssertEqual(log.latest(.query)?.message, "e4")
    }

    func testDecisionLogKeepsLastIssuedPerDay() throws {
        let h = scoredHarness()
        var log = DecisionLog(retentionDays: 2)
        let b = h.brief(today: today, now: noon)
        log.record(b, at: noon)
        var later = b
        later.plan.directive = .recover
        log.record(later, at: noon.addingTimeInterval(60))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].directive, .recover)
        XCTAssertEqual(log.entries[0].engineVersion, MarginCoreInfo.engineVersion)
        var older = b
        older.day = today.adding(-1, calendar: testCalendar)
        var oldest = b
        oldest.day = today.adding(-2, calendar: testCalendar)
        log.record(oldest, at: noon)
        log.record(older, at: noon)
        XCTAssertEqual(log.entries.map(\.day), [older.day, today], "retention drops the oldest")
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(DecisionLog.self, from: data), log)
    }

    func testRuntimeStatusKeepsRecentBackgroundRuns() {
        var s = AppRuntimeStatus()
        for k in 0..<25 { s.recordBackgroundRun(Date(timeIntervalSince1970: Double(k))) }
        XCTAssertEqual(s.backgroundRuns.count, 20)
        XCTAssertEqual(s.backgroundRuns.first, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(s.lastBackgroundTaskRun, Date(timeIntervalSince1970: 24))
    }

    // MARK: Product language

    /// User-facing text produced by the core must not imply diagnosis, illness,
    /// guaranteed safety or injury prevention.
    func testUserFacingCoreTextAvoidsMedicalClaims() {
        let banned = ["ill", "sick", "diagnos", "disease", "infection", "injury", "safe", "guarantee", "medical"]
        var texts: [String] = []
        let scenarios: [[Day: NightSpec?]] = [
            [:],
            [today: NightSpec(hrvMs: 30, sleepingHR: 60, temperature: 36)],
            [today: NightSpec(hrvMs: nil, sleepingHR: 45)],
            [today: NightSpec(hrvMs: nil, sleepingHR: nil, asleepHours: nil)],
            [today: NightSpec(hrvMs: 90, sleepingHR: 44)],
        ]
        for o in scenarios {
            let b = scoredHarness(override: o).brief(today: today, now: noon)
            texts += b.plan.reasons + [b.recovery.statusDetail] + b.plan.trace.map { $0.rule + " " + $0.detail }
            let w = ComplicationState.make(brief: b, now: noon, calendar: testCalendar)
            texts += [w.headline, w.detail, w.footnote, w.inline]
        }
        texts += Flag.allCases.map(ComplicationState.flagLabel) + Directive.allCases.map(ComplicationState.directiveTitle)
        for t in texts {
            let words = t.lowercased().split { !$0.isLetter }.map(String.init)
            for w in words {
                XCTAssertFalse(banned.contains { w.hasPrefix($0) }, "'\(w)' in: \(t)")
            }
        }
    }
}
