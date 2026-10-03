import XCTest
@testable import MarginCore

final class DayTests: XCTestCase {
    func testStringRoundTripAndOrdering() {
        let d = Day(year: 2026, month: 1, day: 9)
        XCTAssertEqual(d.description, "2026-01-09")
        XCTAssertEqual(Day(string: "2026-01-09"), d)
        XCTAssertNil(Day(string: "2026-13-01"))
        XCTAssertNil(Day(string: "garbage"))
        XCTAssertLessThan(Day(year: 2025, month: 12, day: 31), d)
    }

    func testAddingAcrossBoundaries() {
        let d = Day(year: 2025, month: 12, day: 31)
        XCTAssertEqual(d.adding(1, calendar: testCalendar), Day(year: 2026, month: 1, day: 1))
        XCTAssertEqual(Day(year: 2028, month: 2, day: 28).adding(1, calendar: testCalendar),
                       Day(year: 2028, month: 2, day: 29))
        XCTAssertEqual(Day(year: 2026, month: 3, day: 1).adding(-1, calendar: testCalendar),
                       Day(year: 2026, month: 2, day: 28))
    }

    func testWindowsAcrossSpringForward() {
        // US DST starts 2026-03-08 at 02:00 local.
        let d = Day(year: 2026, month: 3, day: 8)
        XCTAssertEqual(d.calendarWindow(calendar: testCalendar).duration, 23 * 3600)
        XCTAssertEqual(d.nightWindow(calendar: testCalendar).duration, 23 * 3600)
        XCTAssertEqual(d.adding(1, calendar: testCalendar), Day(year: 2026, month: 3, day: 9))
        let normal = Day(year: 2026, month: 3, day: 10)
        XCTAssertEqual(normal.calendarWindow(calendar: testCalendar).duration, 24 * 3600)
        XCTAssertEqual(normal.fallbackOvernightWindow(calendar: testCalendar).duration, 14 * 3600)
    }

    func testWindowsAcrossFallBack() {
        // US DST ends 2026-11-01 at 02:00 local.
        let d = Day(year: 2026, month: 11, day: 1)
        XCTAssertEqual(d.calendarWindow(calendar: testCalendar).duration, 25 * 3600)
    }

    func testRange() {
        let a = Day(year: 2026, month: 2, day: 27)
        let b = Day(year: 2026, month: 3, day: 2)
        XCTAssertEqual(Day.range(from: a, to: b, calendar: testCalendar).count, 4)
        XCTAssertTrue(Day.range(from: b, to: a, calendar: testCalendar).isEmpty)
    }
}
