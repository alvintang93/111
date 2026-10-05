import XCTest
@testable import MarginCore

/// Pre-registered metric pairs: minimum sample size, lag and Holm control.
final class InsightTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }

    func series(_ m: CompareMetric, _ values: [Double]) -> MetricSeries {
        MetricSeries(metric: m, points: values.enumerated().map { DayValue(day: today.adding($0.offset - values.count + 1, calendar: cal), value: $0.element) })
    }

    func testInsufficientPairsAreNotTested() {
        let r = MetricPairs.analyse([series(.sleepHours, Array(repeating: 7, count: 10).enumerated().map { 7 + Double($0.offset) / 10 }),
                                     series(.hrv, (0..<10).map { 50 + Double($0) })], calendar: cal)
        let p = r.first { $0.a == .sleepHours && $0.b == .hrv }!
        XCTAssertEqual(p.n, 10)
        XCTAssertFalse(p.sufficient)
        XCTAssertNil(p.rho)
        XCTAssertFalse(p.significant)
    }

    func testStrongRelationshipSurvivesHolmAndLagIsApplied() {
        var rng = SeededNormal(seed: 3)
        let load = (0..<40).map { _ in 60 + 20 * rng.next() }
        // HRV the next day falls with load.
        var hrv = Array(repeating: 55.0, count: 40)
        for k in 1..<40 { hrv[k] = 70 - 0.25 * load[k - 1] + rng.next() }
        let noise = (0..<40).map { _ in 7 + rng.next() }
        let r = MetricPairs.analyse([series(.load, load), series(.hrv, hrv), series(.sleepHours, noise)], calendar: cal)
        let lagged = r.first { $0.a == .load && $0.b == .hrv }!
        XCTAssertEqual(lagged.lagDays, 1)
        XCTAssertEqual(lagged.n, 39, "the last day has no next day yet")
        XCTAssertLessThan(lagged.rho!, -0.7)
        XCTAssertTrue(lagged.significant)
        let null = r.first { $0.a == .sleepHours && $0.b == .hrv }!
        XCTAssertTrue(null.sufficient)
        XCTAssertFalse(null.significant, "no relationship by construction")
    }

    func testBriefIncludesInsightsFromRealSeries() {
        let days = Day.range(from: today.adding(-70, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 12), input: RawFixture.input(days: days, spec: RawFixture.noisySpec(seed: 4)))
        let b = h.brief(today: today, now: at(today, 12))
        let ins = b.metricInsights!
        XCTAssertEqual(ins.count, MetricPairs.pairs.count)
        let caffeine = ins.first { $0.a == .caffeine }!
        XCTAssertEqual(caffeine.n, 0, "no caffeine logged: nothing is tested")
        XCTAssertFalse(caffeine.sufficient)
        XCTAssertTrue(ins.allSatisfy { !$0.sufficient || $0.n >= MetricPairs.minimumN })
        XCTAssertTrue(b.series!.contains { $0.metric == .respiratoryRate && !$0.points.isEmpty })
    }
}
