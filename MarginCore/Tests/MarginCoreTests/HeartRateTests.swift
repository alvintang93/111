import XCTest
@testable import MarginCore

final class HeartRateTests: XCTestCase {
    let d = Day(year: 2026, month: 6, day: 10)
    let floor = ModelParameters.standard.activityFloorHRR

    func steady(_ bpm: Double, from start: Date, minutes: Int, every step: TimeInterval = 5) -> [HRSample] {
        (0..<Int(Double(minutes) * 60 / step)).map {
            HRSample(date: start.addingTimeInterval(Double($0) * step), bpm: bpm)
        }
    }

    func testBanisterTRIMPMatchesClosedForm() {
        let start = at(d, 7)
        let samples = steady(150, from: start, minutes: 60)
        let window = DateInterval(start: start, end: start.addingTimeInterval(3600))
        let h = HeartRateHistogram.build(samples: samples, window: window, maxGap: 300)
        XCTAssertEqual(h.totalSeconds, 3600, accuracy: 1e-9)
        XCTAssertEqual(h.trimp(hrRest: 50, hrMax: 190, sex: .male, floorHRR: floor)!, 108.09535934022335, accuracy: 1e-9)
        XCTAssertEqual(h.trimp(hrRest: 50, hrMax: 190, sex: .female, floorHRR: floor)!, 121.4990663906425, accuracy: 1e-9)
        XCTAssertEqual(h.trimp(hrRest: 50, hrMax: 190, sex: .unspecified, floorHRR: floor)!, 108.09535934022335, accuracy: 1e-9)
    }

    func testMixedIntensities() {
        let h = HeartRateHistogram(secondsByBPM: [120: 1800, 170: 1800])
        XCTAssertEqual(h.trimp(hrRest: 50, hrMax: 190, sex: .male, floorHRR: floor)!, 110.39783138427494, accuracy: 1e-9)
    }

    func testFloorRemovesDailyLiving() {
        let h = HeartRateHistogram(secondsByBPM: [70: 14.0 * 3600, 85: 3600.0])
        XCTAssertEqual(h.trimp(hrRest: 50, hrMax: 190, sex: .male, floorHRR: floor), 0)
    }

    func testGapsAreCappedAndDuplicatesNotDoubleCounted() {
        let t0 = at(d, 9)
        let samples = [
            HRSample(date: t0, bpm: 100),
            HRSample(date: t0, bpm: 101),          // duplicate timestamp from a second source
            HRSample(date: t0.addingTimeInterval(3600), bpm: 100),
        ]
        let window = d.calendarWindow(calendar: testCalendar)
        let h = HeartRateHistogram.build(samples: samples, window: window, maxGap: 300)
        XCTAssertEqual(h.totalSeconds, 600, accuracy: 1e-9)
    }

    func testSamplesOutsideWindowIgnored() {
        let window = d.calendarWindow(calendar: testCalendar)
        let samples = [HRSample(date: window.start.addingTimeInterval(-10), bpm: 150),
                       HRSample(date: window.end, bpm: 150)]
        XCTAssertEqual(HeartRateHistogram.build(samples: samples, window: window, maxGap: 300).totalSeconds, 0)
    }

    func testZonesAndInvalidRange() {
        let h = HeartRateHistogram(secondsByBPM: [100: 60, 130: 60, 190: 60])
        // HRR: 100 -> 0.357, 130 -> 0.571, 190 -> 1.0
        XCTAssertEqual(h.zoneSeconds(hrRest: 50, hrMax: 190), [60, 60, 0, 0, 0, 60])
        XCTAssertNil(h.trimp(hrRest: 60, hrMax: 75, sex: .male, floorHRR: floor))
    }

    func testOutOfRangeBPMIsClamped() {
        let h = HeartRateHistogram(secondsByBPM: [400: 60])
        XCTAssertEqual(h.seconds[HeartRateHistogram.maxBPM], 60)
    }
}
