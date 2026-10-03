import XCTest
@testable import MarginCore

final class EngineTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    let fixedNow = Date(timeIntervalSince1970: 1_782_800_000)

    func engine(_ records: [DayRecord], settings: UserSettings = UserSettings(age: 35, sex: .male)) -> Engine {
        Engine(records: records, today: today, settings: settings, calendar: testCalendar)
    }

    func replacingToday(_ records: [DayRecord], with r: DayRecord) -> [DayRecord] {
        records.filter { $0.day != today } + [r]
    }

    func testBaselineDayIsMidRangeWithHighConfidence() {
        // Today sits exactly on the generating means of the synthetic history.
        let records = replacingToday(syntheticHistory(today: today, count: 90),
                                     with: syntheticRecord(day: today, lnHRV: log(55), sleepingHR: 50,
                                                           asleepHours: 7.6))
        let brief = engine(records).brief(generatedAt: fixedNow)
        let r = brief.recovery
        XCTAssertEqual(r.confidence, .high)
        XCTAssertNotNil(r.score)
        XCTAssertTrue((35...65).contains(r.score!), "score \(r.score!)")
        XCTAssertEqual(r.baselineDays, 60)
        XCTAssertEqual(r.components.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-12)
        XCTAssertFalse(r.flags.contains(.illnessWatch))
        XCTAssertNotNil(brief.plan.targetLow)
        XCTAssertNotNil(brief.load.acwr)
        XCTAssertEqual(brief.history.count, 14)
        XCTAssertEqual(brief.hrMaxUsed, 208 - 0.7 * 35, accuracy: 1e-12)
        XCTAssertEqual(brief.hrRestUsed, 55)
    }

    func testSuppressedHRVAndElevatedHRGivesRecover() {
        var records = syntheticHistory(today: today, count: 90)
        records = replacingToday(records, with: syntheticRecord(day: today, lnHRV: log(55) - 0.35, sleepingHR: 56))
        let brief = engine(records).brief(generatedAt: fixedNow)
        XCTAssertEqual(brief.recovery.band, .depleted)
        XCTAssertEqual(brief.plan.directive, .recover)
        XCTAssertEqual(brief.plan.targetLow, 0)
        let hrv = brief.recovery.components.first { $0.kind == .hrv }!
        XCTAssertLessThan(hrv.z, -2)
        XCTAssertEqual(hrv.value, 55 * exp(-0.35), accuracy: 1e-9)
    }

    func testHighHRVGivesPushWithinCeiling() {
        var records = syntheticHistory(today: today, count: 90)
        records = replacingToday(records, with: syntheticRecord(day: today, lnHRV: log(55) + 0.25, sleepingHR: 47.5))
        let e = engine(records)
        let brief = e.brief(generatedAt: fixedNow)
        XCTAssertEqual(brief.recovery.band, .primed)
        XCTAssertEqual(brief.plan.directive, .push)
        let high = brief.plan.targetHigh!, ceiling = brief.plan.ceiling!
        XCTAssertLessThanOrEqual(high, ceiling + 1e-9)
        XCTAssertLessThanOrEqual(brief.plan.targetLow!, high)
    }

    func testIllnessRequiresConjunction() {
        var records = syntheticHistory(today: today, count: 90)
        // Elevated sleeping HR alone: no illness flag (guards against false alarms).
        records = replacingToday(records, with: syntheticRecord(day: today, lnHRV: log(55), sleepingHR: 58))
        XCTAssertFalse(engine(records).brief(generatedAt: fixedNow).recovery.flags.contains(.illnessWatch))
        // Plus elevated temperature: flag + rest.
        records = replacingToday(records, with: syntheticRecord(day: today, lnHRV: log(55), sleepingHR: 58,
                                                                temperature: 35.2))
        let brief = engine(records).brief(generatedAt: fixedNow)
        XCTAssertTrue(brief.recovery.flags.contains(.illnessWatch))
        XCTAssertEqual(brief.plan.directive, .rest)
        XCTAssertLessThanOrEqual(brief.plan.targetHigh!, 0.3 * brief.load.ctl! + 1e-9)
    }

    func testCalibratingWithShortHistory() {
        let brief = engine(syntheticHistory(today: today, count: 10)).brief(generatedAt: fixedNow)
        XCTAssertEqual(brief.recovery.confidence, .calibrating)
        XCTAssertNil(brief.recovery.score)
        XCTAssertEqual(brief.plan.directive, .calibrating)
        XCTAssertNil(brief.plan.targetHigh)
        XCTAssertNil(brief.load.acwr)
    }

    func testMissingOvernightDataIsNoDataNotAScore() {
        var records = syntheticHistory(today: today, count: 90)
        records = replacingToday(records, with: syntheticRecord(day: today, lnHRV: nil, sleepingHR: nil, asleepHours: nil))
        let brief = engine(records).brief(generatedAt: fixedNow)
        XCTAssertEqual(brief.recovery.confidence, .noData)
        XCTAssertNil(brief.recovery.score)
        XCTAssertEqual(brief.plan.directive, .noData)
        XCTAssertNil(brief.sleep)
    }

    func testLowConfidenceDemotesPush() {
        var records = syntheticHistory(today: today, count: 90)
        // HRV only (no sleeping HR, no sleep) -> low confidence.
        records = replacingToday(records, with: syntheticRecord(day: today, lnHRV: log(55) + 0.3, sleepingHR: nil,
                                                                asleepHours: nil))
        let brief = engine(records).brief(generatedAt: fixedNow)
        XCTAssertEqual(brief.recovery.confidence, .low)
        XCTAssertEqual(brief.recovery.band, .primed)
        XCTAssertEqual(brief.plan.directive, .maintain)
    }

    func testLoadSpikeIsFlaggedAndCapped() {
        var records = syntheticHistory(today: today, count: 90)
        // Last 7 completed days: very hard sessions.
        for k in 1...7 {
            let d = today.adding(-k, calendar: testCalendar)
            let old = records.first { $0.day == d }!
            records = records.filter { $0.day != d } + [syntheticRecord(day: d, lnHRV: old.lnHRV, sleepingHR: old.sleepingHR,
                                                                         workoutMinutes: 180, workoutBPM: 165)]
        }
        let brief = engine(records).brief(generatedAt: fixedNow)
        XCTAssertGreaterThan(brief.load.acwr!, 1.5)
        XCTAssertTrue(brief.recovery.flags.contains(.loadSpike))
        XCTAssertNotEqual(brief.plan.directive, .push)
        XCTAssertEqual(brief.plan.ceiling, 0)
        XCTAssertEqual(brief.plan.targetHigh, 0)
    }

    func testSexChangesLoadButNotRecovery() {
        let records = syntheticHistory(today: today, count: 90)
        let m = engine(records, settings: UserSettings(age: 35, sex: .male)).brief(generatedAt: fixedNow)
        let f = engine(records, settings: UserSettings(age: 35, sex: .female)).brief(generatedAt: fixedNow)
        XCTAssertNotEqual(m.load.ctl, f.load.ctl)
        XCTAssertEqual(m.recovery.composite, f.recovery.composite)
    }

    func testDeterministicAndCodableRoundTrip() throws {
        let records = syntheticHistory(today: today, count: 90)
        let a = engine(records).brief(generatedAt: fixedNow)
        let b = engine(records.reversed()).brief(generatedAt: fixedNow)
        XCTAssertEqual(a, b)
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(DailyBrief.self, from: data), a)
        let recData = try JSONEncoder().encode(records)
        XCTAssertEqual(try JSONDecoder().decode([DayRecord].self, from: recData), records)
    }

    func testNoLookAhead() {
        // A wild future record must not change today's brief.
        let records = syntheticHistory(today: today, count: 90)
        let future = syntheticRecord(day: today.adding(3, calendar: testCalendar), lnHRV: 1, sleepingHR: 120)
        XCTAssertEqual(engine(records).brief(generatedAt: fixedNow),
                       engine(records + [future]).brief(generatedAt: fixedNow))
    }

    func testEmptyRecords() {
        let brief = engine([]).brief(generatedAt: fixedNow)
        XCTAssertEqual(brief.recovery.confidence, .calibrating)
        XCTAssertEqual(brief.load.historyDays, 0)
        XCTAssertEqual(brief.history.count, 1)
    }
}

final class DayRecordBuilderTests: XCTestCase {
    let d = Day(year: 2026, month: 6, day: 10)

    func testBuildsFromRawSamples() {
        let prev = d.adding(-1, calendar: testCalendar)
        let onset = at(prev, 23), wake = at(d, 7)
        var hr: [HRSample] = stride(from: 0.0, to: 8 * 3600, by: 300).map {
            HRSample(date: onset.addingTimeInterval($0), bpm: 48 + ($0.truncatingRemainder(dividingBy: 1500) / 300))
        }
        hr += (0..<720).map { HRSample(date: at(d, 18).addingTimeInterval(Double($0) * 5), bpm: 150) }
        let input = RawDayInput(
            sleep: [SleepSegment(start: onset, end: wake, stage: .core, sourcePriority: 2)],
            hrv: [TimedValue(start: at(d, 2), end: at(d, 2, 1), value: 60),
                  TimedValue(start: at(d, 5), end: at(d, 5, 1), value: 40),
                  TimedValue(start: at(d, 12), end: at(d, 12, 1), value: 10)],   // daytime: excluded
            heartRate: hr,
            restingHR: [TimedValue(start: at(d, 8), end: at(d, 20), value: 54)],
            respiratoryRate: [TimedValue(start: at(d, 1), end: at(d, 1, 5), value: 14),
                              TimedValue(start: at(d, 4), end: at(d, 4, 5), value: 15)],
            wristTemperature: [TimedValue(start: onset, end: wake, value: 34.6)]
        )
        let r = DayRecordBuilder.build(day: d, calendar: testCalendar, input: input)
        XCTAssertEqual(r.sleep?.asleep, 8 * 3600)
        XCTAssertEqual(r.lnHRV!, (log(60) + log(40)) / 2, accuracy: 1e-12)
        XCTAssertEqual(r.hrvSampleCount, 2)
        XCTAssertTrue(r.hrvDuringSleep)
        XCTAssertEqual(r.sleepingHR!, 48, accuracy: 1e-9)
        XCTAssertEqual(r.appleRestingHR, 54)
        XCTAssertEqual(r.respiratoryRate, 14.5)
        XCTAssertEqual(r.wristTemperature, 34.6)
        // Calendar-day activity: 84 overnight samples after midnight (300 s each) + workout.
        // The final workout sample holds for the 300 s gap cap because nothing follows it.
        XCTAssertEqual(r.activity.seconds[150], 719 * 5 + 300, accuracy: 1e-9)
        XCTAssertEqual(r.activity.totalSeconds, 84 * 300 + 719 * 5 + 300, accuracy: 1e-9)
    }

    func testFallbackWindowWhenNoSleep() {
        let input = RawDayInput(hrv: [TimedValue(start: at(d, 6), end: at(d, 6, 1), value: 50)])
        let r = DayRecordBuilder.build(day: d, calendar: testCalendar, input: input)
        XCTAssertNil(r.sleep)
        XCTAssertEqual(r.lnHRV!, log(50), accuracy: 1e-12)
        XCTAssertFalse(r.hrvDuringSleep)
        XCTAssertNil(r.sleepingHR)
    }
}
