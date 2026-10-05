import XCTest
@testable import MarginCore

/// Explanations, sleep stage timelines, workout analysis and routine sync.
final class ExplainTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }

    func testExplanationNamesTheInputThatMovedTheScore() throws {
        var records = syntheticHistory(today: today, count: 90)
        records = records.filter { $0.day != today } + [syntheticRecord(day: today, lnHRV: log(55) - 0.35, sleepingHR: 50)]
        let b = Engine(records: records, today: today, settings: UserSettings(age: 35, sex: .male), calendar: cal).brief()
        let e = try XCTUnwrap(b.explanation)
        XCTAssertTrue(e.headline.hasPrefix("Recovery \(b.recovery.score!)"))
        XCTAssertTrue(e.headline.contains("down"), e.headline)
        XCTAssertEqual(e.drivers.first?.kind, .hrv)
        XCTAssertTrue(e.lines.first!.hasPrefix("HRV"), e.lines.first!)
        XCTAssertTrue(e.lines.first!.contains("lowered"))
        XCTAssertEqual(e.comparedWith, today.adding(-1, calendar: cal))
        // Contributions are the engine's own numbers.
        let hrv = b.recovery.components.first { $0.kind == .hrv }!
        XCTAssertEqual(e.drivers.first!.now!, hrv.contribution, accuracy: 1e-12)
    }

    func testNoScoreExplainsTheStatus() {
        let b = Engine(records: syntheticHistory(today: today, count: 5), today: today, settings: UserSettings(), calendar: cal).brief()
        XCTAssertEqual(b.explanation?.headline, b.recovery.statusDetail)
        XCTAssertEqual(b.explanation?.lines, [])
    }

    func testStageTimelineAddsUpToTheTotals() throws {
        let onset = at(today.adding(-1, calendar: cal), 23)
        let segs = [SleepSegment(start: onset, end: onset.addingTimeInterval(3600), stage: .core, sourcePriority: 2),
                    SleepSegment(start: onset.addingTimeInterval(3600), end: onset.addingTimeInterval(5400), stage: .deep, sourcePriority: 2),
                    SleepSegment(start: onset.addingTimeInterval(5400), end: onset.addingTimeInterval(5700), stage: .awake, sourcePriority: 2),
                    SleepSegment(start: onset.addingTimeInterval(5700), end: onset.addingTimeInterval(9000), stage: .rem, sourcePriority: 2)]
        let n = try XCTUnwrap(SleepAggregator.aggregate(segments: segs, window: today.nightWindow(calendar: cal), boutMergeGap: 5400))
        let stages = try XCTUnwrap(n.stages)
        XCTAssertEqual(stages.map(\.stage), [.core, .deep, .awake, .rem])
        func total(_ s: SleepStage) -> TimeInterval { stages.filter { $0.stage == s }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
        XCTAssertEqual(total(.deep), n.deep)
        XCTAssertEqual(total(.rem), n.rem)
        XCTAssertEqual(total(.awake), n.awake)
        XCTAssertEqual(stages.map(\.start), stages.map(\.start).sorted())
    }

    func testWorkoutAnalysisCurveZonesAndLoad() throws {
        let start = at(today, 18), end = at(today, 18, 30)
        var hr = stride(from: 0.0, to: 1800, by: 5).map { HRSample(date: start.addingTimeInterval($0), bpm: $0 < 900 ? 130 : 170) }
        hr += [HRSample(date: end.addingTimeInterval(60), bpm: 140), HRSample(date: end.addingTimeInterval(150), bpm: 115)]
        let d = WorkoutRecoveryAnalyzer.analyze(workouts: [WorkoutSample(start: start, end: end, activityType: 37)], heartRate: hr, appleRecovery: [])[0]
        XCTAssertEqual(d.hrCurve?.count, 66, "30 min + 3 min recovery in 30 s steps")
        let a = WorkoutAnalysis.make(d, hrRest: 55, hrMax: 185, sex: .male, floorHRR: 0.3, zones: .standard, strainReference: 60)
        let direct = HeartRateHistogram(secondsByBPM: d.hrSeconds).trimp(hrRest: 55, hrMax: 185, sex: .male, floorHRR: 0.3)!
        XCTAssertEqual(a.load, direct, accuracy: 1e-9)
        XCTAssertEqual(a.zoneMinutes.reduce(0, +), 30, accuracy: 0.2)
        XCTAssertEqual(a.curve.first?.zone, 1, "130 bpm is 58% of reserve: zone 1 (50-60%)")
        XCTAssertEqual(a.curve.first { !$0.afterEnd && $0.seconds >= 900 }?.zone, 4, "170 bpm is 88% of reserve")
        XCTAssertTrue(a.curve.last!.afterEnd)
        XCTAssertEqual(a.focus, .highAerobic, "half the time in zone 4, none in zone 5")
    }

    func testRoutineSyncMergeRules() {
        let t0 = at(today, 8)
        let r = Routine(name: "Legs", items: [.exercise("back-squat")], createdAt: t0)
        var watch = RoutineLibrary(routines: [r])
        var phone = watch
        // A newer edit on the phone wins.
        var edited = r
        edited.name = "Legs heavy"
        phone.update(edited, at: t0.addingTimeInterval(60))
        XCTAssertEqual(watch.merged(with: phone).routine(r.id)?.name, "Legs heavy")
        XCTAssertEqual(phone.merged(with: watch), watch.merged(with: phone), "order doesn't matter")
        // A delete on the watch after that edit wins.
        watch.delete(r.id, at: t0.addingTimeInterval(120))
        XCTAssertNil(phone.merged(with: watch).routine(r.id))
        // An edit made after the delete brings it back.
        var later = edited
        later.items.append(.exercise("leg-press"))
        phone.update(later, at: t0.addingTimeInterval(180))
        XCTAssertEqual(watch.merged(with: phone).routine(r.id)?.items.count, 2)
        // New routines from both sides are kept.
        let a = watch.create(name: "A", at: t0), b = phone.create(name: "B", at: t0)
        let m = watch.merged(with: phone)
        XCTAssertNotNil(m.routine(a.id))
        XCTAssertNotNil(m.routine(b.id))
    }
}
