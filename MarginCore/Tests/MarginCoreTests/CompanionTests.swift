import XCTest
@testable import MarginCore

/// Batch 4: the watch → iPhone payload and lab results.
final class CompanionTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }

    func brief() -> DailyBrief {
        let days = Day.range(from: today.adding(-20, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 12), input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        return h.brief(today: today, now: at(today, 12))
    }

    func testPayloadRoundTripsAndKeepsJournal() throws {
        let b = brief()
        let log = StrengthLog(sessions: [StrengthSession(start: at(today, 18), sets: [
            StrengthSet(exerciseID: "bench-press", date: at(today, 18), weightKg: 80, reps: 5),
        ])])
        let p = PhonePayload(sentAt: at(today, 12), brief: b, strength: log, journal: [today: ["Sauna", "Alcohol"]],
                             lifestyle: LifestyleSettings())
        XCTAssertEqual(p.journal[today.description], ["Alcohol", "Sauna"])
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(PhonePayload.decode(data), .ok(p))
        XCTAssertEqual(p.engineVersion, MarginCoreInfo.engineVersion)
    }

    func testPayloadRejectsNewerVersionsAndGarbage() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PhonePayload(sentAt: at(today, 12), brief: brief(), strength: nil, journal: [:], lifestyle: LifestyleSettings()))) as! [String: Any]
        json["version"] = PhonePayload.version + 1
        XCTAssertEqual(PhonePayload.decode(try JSONSerialization.data(withJSONObject: json)), .newerVersion(PhonePayload.version + 1))
        if case .corrupt = PhonePayload.decode(Data("nope".utf8)) {} else { XCTFail("garbage must be corrupt") }
        if case .corrupt = PhonePayload.decode(Data(#"{"version":1}"#.utf8)) {} else { XCTFail("missing fields must be corrupt") }
    }

    func testLabSeriesGroupingAndReference() {
        let d1 = at(today.adding(-200, calendar: cal), 9), d2 = at(today, 9)
        let results = [
            LabResult(marker: .ldl, value: 130, date: d1, referenceHigh: 100),
            LabResult(marker: .ldl, value: 95, date: d2, referenceHigh: 100),
            LabResult(marker: .ldl, value: 3.1, unit: "mmol/L", date: d2),
            LabResult(marker: .custom, name: "Omega-3 index", value: 6.2, unit: "%", date: d1),
            LabResult(marker: .custom, name: "omega-3 index", value: 7.0, unit: "%", date: d2),
        ]
        let series = LabSeries.group(results)
        XCTAssertEqual(series.count, 3, "different units are different series; custom names match case-insensitively")
        let ldl = series.first { $0.key == "ldl:mg/dl" }!
        XCTAssertEqual(ldl.results.map(\.value), [130, 95])
        XCTAssertEqual(ldl.change, -35)
        XCTAssertEqual(ldl.latest.withinReference, true)
        XCTAssertEqual(ldl.results[0].withinReference, false)
        XCTAssertNil(series.first { $0.key == "ldl:mmol/l" }!.latest.withinReference, "no range entered")
        XCTAssertEqual(series.first { $0.key.hasPrefix("custom:") }!.results.count, 2)
        XCTAssertEqual(LabResult(marker: .hba1c, value: 5.4, date: d2).unit, "%")
    }
}
