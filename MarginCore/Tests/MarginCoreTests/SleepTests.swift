import XCTest
@testable import MarginCore

final class SleepTests: XCTestCase {
    let d = Day(year: 2026, month: 6, day: 10)
    var prev: Day { d.adding(-1, calendar: testCalendar) }
    var window: DateInterval { d.nightWindow(calendar: testCalendar) }
    let gap: TimeInterval = 90 * 60

    func seg(_ s: Date, _ e: Date, _ stage: SleepStage, _ p: Int = 2) -> SleepSegment {
        SleepSegment(start: s, end: e, stage: stage, sourcePriority: p)
    }

    func testPrefersWatchSourceOverPhone() {
        let segs = [
            seg(at(prev, 22), at(d, 7), .inBed, 1),
            seg(at(prev, 22, 30), at(d, 6, 30), .asleepUnspecified, 1),
            seg(at(prev, 23), at(d, 3), .core),
            seg(at(d, 3), at(d, 4), .deep),
            seg(at(d, 4), at(d, 4, 10), .awake),
            seg(at(d, 4, 10), at(d, 6, 30), .rem),
        ]
        let n = SleepAggregator.aggregate(segments: segs, window: window, boutMergeGap: gap)!
        XCTAssertEqual(n.asleep, (4 * 60 + 60 + 140) * 60)
        XCTAssertEqual(n.awake, 10 * 60)
        XCTAssertEqual(n.deep, 3600)
        XCTAssertEqual(n.rem, 140 * 60)
        XCTAssertEqual(n.unspecified, 0)
        XCTAssertEqual(n.mainOnset, at(prev, 23))
        XCTAssertEqual(n.mainWake, at(d, 6, 30))
    }

    func testOverlapWithinSourceIsNotDoubleCounted() {
        let segs = [seg(at(prev, 23), at(d, 7), .core), seg(at(d, 1), at(d, 2), .deep)]
        let n = SleepAggregator.aggregate(segments: segs, window: window, boutMergeGap: gap)!
        XCTAssertEqual(n.asleep, 8 * 3600)
        XCTAssertEqual(n.core, 7 * 3600)
        XCTAssertEqual(n.deep, 3600)
    }

    func testNapCountsTowardTotalButNotMainBout() {
        let segs = [seg(at(prev, 23), at(d, 7), .core), seg(at(d, 14), at(d, 14, 30), .core)]
        let n = SleepAggregator.aggregate(segments: segs, window: window, boutMergeGap: gap)!
        XCTAssertEqual(n.asleep, 8.5 * 3600)
        XCTAssertEqual(n.mainAsleep, 8 * 3600)
        XCTAssertEqual(n.mainWake, at(d, 7))
        XCTAssertEqual(n.efficiency!, 1, accuracy: 1e-12)
    }

    func testEfficiencyCountsAwakeInsideBout() {
        let segs = [
            seg(at(prev, 23), at(d, 3), .core),
            seg(at(d, 3), at(d, 3, 30), .awake),
            seg(at(d, 3, 30), at(d, 7), .core),
        ]
        let n = SleepAggregator.aggregate(segments: segs, window: window, boutMergeGap: gap)!
        XCTAssertEqual(n.mainAsleep, 7.5 * 3600)
        XCTAssertEqual(n.efficiency!, 7.5 / 8, accuracy: 1e-12)
    }

    func testClipsToWindow() {
        let segs = [seg(at(prev, 17), at(prev, 19), .core), seg(at(d, 17), at(d, 20), .core)]
        let n = SleepAggregator.aggregate(segments: segs, window: window, boutMergeGap: gap)!
        XCTAssertEqual(n.asleep, 2 * 3600)
    }

    func testNoSleepReturnsNil() {
        XCTAssertNil(SleepAggregator.aggregate(segments: [seg(at(prev, 22), at(d, 7), .inBed)],
                                               window: window, boutMergeGap: gap))
        XCTAssertNil(SleepAggregator.aggregate(segments: [], window: window, boutMergeGap: gap))
    }

    func testSleepNeedDebtAndStrain() {
        let p = ModelParameters.standard
        // 7 nights at 7h with 8h base -> 7h debt -> repay min(1.4h, 1h) = 1h.
        let need = SleepModel.need(baseHours: 8, priorNightsAsleep: Array(repeating: 7 * 3600, count: 7),
                                   priorDayLoad: 200, ctl: 100, params: p)
        XCTAssertEqual(need.debt, 7 * 3600)
        XCTAssertEqual(need.debtRepayment, 3600)
        XCTAssertEqual(need.strainAdjustment, 1800)
        XCTAssertEqual(need.total, 9.5 * 3600)
        // Missing nights are not counted as debt; small CTL disables strain adjustment.
        let sparse = SleepModel.need(baseHours: 8, priorNightsAsleep: [nil, nil, 8.0 * 3600],
                                     priorDayLoad: 500, ctl: 5, params: p)
        XCTAssertEqual(sparse.total, 8 * 3600)
    }

    func testSleepScore() {
        XCTAssertEqual(SleepModel.score(performance: 1, efficiency: 0.95, midpointSDMinutes: 15), 100)
        XCTAssertEqual(SleepModel.score(performance: 1.2, efficiency: nil, midpointSDMinutes: nil), 100)
        XCTAssertEqual(SleepModel.score(performance: 0.5, efficiency: 0.70, midpointSDMinutes: 90), 35)
    }
}
