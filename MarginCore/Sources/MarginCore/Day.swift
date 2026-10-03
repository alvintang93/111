import Foundation

/// A local calendar day. All windowing is derived from this type so that
/// day boundaries are computed in exactly one place.
public struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Parses `yyyy-MM-dd`.
    public init?(string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Local wall-clock time on this day. `hour` must be 0...23.
    public func date(hour: Int = 0, calendar: Calendar) -> Date {
        precondition((0...23).contains(hour), "hour out of range")
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        c.hour = hour
        return calendar.date(from: c)!
    }

    /// Adds whole days. Anchored at noon so DST transitions cannot shift the result.
    public func adding(_ days: Int, calendar: Calendar) -> Day {
        let noon = date(hour: 12, calendar: calendar)
        return Day(calendar.date(byAdding: .day, value: days, to: noon)!, calendar: calendar)
    }

    /// Midnight-to-midnight window for this day (activity / training load).
    public func calendarWindow(calendar: Calendar) -> DateInterval {
        DateInterval(start: date(calendar: calendar),
                     end: adding(1, calendar: calendar).date(calendar: calendar))
    }

    /// 18:00 the previous day to 18:00 this day. Sleep ending in this window
    /// (including afternoon naps) is attributed to this day.
    public func nightWindow(calendar: Calendar) -> DateInterval {
        DateInterval(start: adding(-1, calendar: calendar).date(hour: 18, calendar: calendar),
                     end: date(hour: 18, calendar: calendar))
    }

    /// Used for overnight physiology only when no sleep was detected: 20:00 the
    /// previous day to 10:00 this day.
    public func fallbackOvernightWindow(calendar: Calendar) -> DateInterval {
        DateInterval(start: adding(-1, calendar: calendar).date(hour: 20, calendar: calendar),
                     end: date(hour: 10, calendar: calendar))
    }

    /// Inclusive range of days, oldest first. Empty if `from > to`.
    public static func range(from: Day, to: Day, calendar: Calendar) -> [Day] {
        guard from <= to else { return [] }
        var out: [Day] = []
        var d = from
        while d <= to {
            out.append(d)
            d = d.adding(1, calendar: calendar)
        }
        return out
    }
}
