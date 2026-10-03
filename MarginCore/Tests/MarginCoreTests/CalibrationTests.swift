import XCTest
@testable import MarginCore

/// Error-rate checks on simulated data with known ground truth.
/// Null = stationary physiology (any "recover" is a false alarm, type I).
/// Alternative = a real, sustained drop (a missed "recover" is type II).
final class CalibrationTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    let settings = UserSettings(age: 35, sex: .male)

    func testStationaryFalseAlarmRates() {
        var scores: [Int] = []
        var directives: [Directive] = []
        for seed in UInt64(1)...20 {
            let e = Engine(records: syntheticHistory(today: today, count: 150, seed: seed), today: today,
                           settings: settings, calendar: testCalendar)
            for i in 80..<e.days.count {
                let r = e.recovery(at: i)
                scores.append(r.score!)
                directives.append(e.directive(for: r).0)
            }
        }
        let n = Double(scores.count)
        let mean = Double(scores.reduce(0, +)) / n
        let bottomBand = Double(scores.filter { $0 <= 33 }.count) / n
        let recover = Double(directives.filter { $0 == .recover }.count) / n
        let rest = Double(directives.filter { $0 == .rest }.count) / n
        print("CALIBRATION null n=\(scores.count) mean=\(mean) bottomBand=\(bottomBand) recover=\(recover) rest=\(rest)")
        XCTAssertEqual(mean, 50, accuracy: 6, "score is centred on the person's typical day")
        XCTAssertEqual(bottomBand, 0.33, accuracy: 0.08, "bands are ~terciles on null data")
        XCTAssertLessThanOrEqual(recover, 0.20, "false 'recover' rate")
        XCTAssertLessThanOrEqual(rest, 0.01, "false illness alarms")
    }

    func testSustainedDropIsDetected() {
        var hits = 0
        let seeds = UInt64(1)...20
        for seed in seeds {
            var records = syntheticHistory(today: today, count: 150, seed: seed)
            // Last 5 nights: HRV -22%, sleeping HR +3 bpm (real accumulated fatigue).
            records = records.map { r in
                guard r.day > today.adding(-5, calendar: testCalendar) else { return r }
                var m = r
                m.lnHRV = r.lnHRV.map { $0 - 0.25 }
                m.sleepingHR = r.sleepingHR.map { $0 + 3 }
                return m
            }
            let e = Engine(records: records, today: today, settings: settings, calendar: testCalendar)
            let r = e.recovery(at: e.todayIndex)
            if e.directive(for: r).0 == .recover { hits += 1 }
        }
        print("CALIBRATION detection=\(hits)/\(seeds.count)")
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(seeds.count), 0.9, "detection rate (1 - type II)")
    }
}
