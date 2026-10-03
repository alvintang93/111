import XCTest
@testable import MarginCore

final class LoadTests: XCTestCase {
    let p = ModelParameters.standard

    func days(_ n: Int) -> [Day] {
        Day.range(from: Day(year: 2026, month: 1, day: 1),
                  to: Day(year: 2026, month: 1, day: 1).adding(n - 1, calendar: testCalendar),
                  calendar: testCalendar)
    }

    func testConstantLoadConverges() {
        let pts = LoadModel.run(days: days(300), loads: Array(repeating: 100, count: 300), params: p)
        XCTAssertEqual(pts.last!.atl, 100, accuracy: 1e-9)
        XCTAssertEqual(pts.last!.ctl, 100, accuracy: 1e-9)
    }

    func testUnobservedDaysCountAsZeroAndAreMarked() {
        var loads: [Double?] = Array(repeating: 100, count: 30)
        loads[29] = nil
        let pts = LoadModel.run(days: days(30), loads: loads, params: p)
        XCTAssertFalse(pts[29].observed)
        XCTAssertEqual(pts[29].load, 0)
        XCTAssertLessThan(pts[29].atl, pts[28].atl)
    }

    func testCeilingHitsTargetRatioExactly() {
        let ka = LoadModel.decay(days: p.atlDays), kc = LoadModel.decay(days: p.ctlDays)
        for (atl, ctl, r) in [(80.0, 100.0, 1.3), (130.0, 100.0, 1.3), (60.0, 90.0, 1.1), (100.0, 100.0, 1.5)] {
            let c = LoadModel.ceiling(atl: atl, ctl: ctl, ratio: r, params: p)!
            let ratio = (atl + (c - atl) * ka) / (ctl + (c - ctl) * kc)
            XCTAssertEqual(ratio, r, accuracy: 1e-9)
        }
        // Already far above ceiling: no load keeps the ratio down, so the ceiling is 0.
        XCTAssertEqual(LoadModel.ceiling(atl: 400, ctl: 100, ratio: 1.3, params: p), 0)
        XCTAssertNil(LoadModel.ceiling(atl: 100, ctl: 100, ratio: 10, params: p))
    }
}

final class TagTests: XCTestCase {
    func testWelchMatchesSciPy() {
        let a = [0.10, -0.05, 0.02, -0.12, -0.20, -0.08, -0.15]
        let b = [0.03, 0.07, -0.02, 0.05, 0.10, 0.01, 0.04, 0.08, -0.01, 0.06]
        let r = Hypothesis.welch(a, b)!
        XCTAssertEqual(r.t, -2.6902052119986686, accuracy: 1e-12)
        XCTAssertEqual(r.p, 0.030176795012649197, accuracy: 1e-12)
        XCTAssertEqual(r.meanDifference, -0.10957142857142857, accuracy: 1e-12)
        XCTAssertNil(Hypothesis.welch([1], b))
        XCTAssertNil(Hypothesis.welch([1, 1], [2, 2]))
    }

    func testHolm() {
        XCTAssertEqual(Hypothesis.holm([0.01, 0.04, 0.03, 0.005], alpha: 0.05), [true, false, false, true])
        XCTAssertEqual(Hypothesis.holm([0.01, 0.02, 0.03], alpha: 0.05), [true, true, true])
        XCTAssertEqual(Hypothesis.holm([], alpha: 0.05), [])
    }

    func testImpactsDetectRealEffectAndIgnoreNoise() {
        var rng = SeededNormal(seed: 7)
        let start = Day(year: 2026, month: 1, day: 1)
        var journal: [Day: Set<String>] = [:]
        var dev: [Day: Double] = [:]
        for k in 0..<120 {
            let day = start.adding(k, calendar: testCalendar)
            var tags: Set<String> = []
            if k % 4 == 0 { tags.insert("Alcohol") }
            if k % 3 == 0 { tags.insert("Sauna") }
            if k % 10 != 5 { journal[day] = tags }     // some days never journaled
            let next = day.adding(1, calendar: testCalendar)
            dev[next] = 0.08 * rng.next() + (tags.contains("Alcohol") ? -0.15 : 0)
        }
        let impacts = TagAnalysis.impacts(journal: journal, hrvDeviation: dev, calendar: testCalendar,
                                          params: .standard)
        let alcohol = impacts.first { $0.tag == "Alcohol" }!
        let sauna = impacts.first { $0.tag == "Sauna" }!
        XCTAssertTrue(alcohol.significant)
        XCTAssertEqual(alcohol.effectPercent, (exp(-0.15) - 1) * 100, accuracy: 5)
        XCTAssertFalse(sauna.significant)
        XCTAssertEqual(alcohol.nWith + alcohol.nWithout, journal.count)
    }

    func testTooFewSamplesAreNotTested() {
        let d = Day(year: 2026, month: 1, day: 1)
        let journal = [d: Set(["Travel"])]
        XCTAssertTrue(TagAnalysis.impacts(journal: journal, hrvDeviation: [:], calendar: testCalendar,
                                          params: .standard).isEmpty)
    }
}
