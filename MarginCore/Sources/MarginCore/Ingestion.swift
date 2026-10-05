import Foundation

/// The HealthKit inputs Margin reads. Used for per-input statistics and diagnostics.
public enum HealthInput: String, Codable, Sendable, CaseIterable {
    case heartRate, hrv, restingHR, respiratoryRate, wristTemperature, sleep, workouts, steps, heartRateRecovery
}

/// What happened to the samples of one input for one day. Counts and dates
/// only — no health values — so it is safe to log and display.
public struct InputStats: Codable, Sendable, Equatable {
    /// Samples overlapping the day's fetch interval, before cleaning.
    public var received = 0
    public var accepted = 0
    /// Exact duplicates removed (same timestamps and value, e.g. two sources).
    public var duplicates = 0
    /// Non-finite, out-of-range, zero/negative-duration or over-long samples.
    public var implausible = 0
    /// Samples starting after the build time (clock skew / bad manual entries).
    public var future = 0
    public var earliest: Date?
    public var latest: Date?

    public init() {}

    public var rejected: Int { duplicates + implausible + future }
}

public struct IngestionStats: Codable, Sendable, Equatable {
    public var inputs: [String: InputStats]

    public init() { inputs = [:] }

    public subscript(_ input: HealthInput) -> InputStats {
        get { inputs[input.rawValue] ?? InputStats() }
        set { inputs[input.rawValue] = newValue }
    }
}

/// Plausibility limits. Values outside are rejected and counted, never clamped.
public struct PlausibilityLimits: Sendable, Equatable {
    public var heartRate: ClosedRange<Double> = 25...250
    public var hrvSDNN: ClosedRange<Double> = 1...400
    public var restingHR: ClosedRange<Double> = 25...200
    public var respiratoryRate: ClosedRange<Double> = 4...60
    /// Wide on purpose: accepts both absolute (~33-37 degC) and deviation-style
    /// (~-3...+3) values, because the stored form must be confirmed on device.
    public var wristTemperature: ClosedRange<Double> = -10...45
    /// Steps per sample.
    public var steps: ClosedRange<Double> = 0...100_000
    /// Apple's one-minute heart-rate recovery (bpm drop).
    public var heartRateRecovery: ClosedRange<Double> = 0...120
    public var maxSampleDuration: TimeInterval = 24 * 3600
    /// Samples starting more than this after the build time are "future".
    public var futureTolerance: TimeInterval = 60

    public init() {}
}

enum Sanitizer {
    static func timed(_ samples: [TimedValue], range: ClosedRange<Double>, within interval: DateInterval,
                      asOf: Date, limits: PlausibilityLimits, stats: inout InputStats) -> [TimedValue] {
        let overlapping = samples.filter { $0.end >= interval.start && $0.start < interval.end }
        stats.received += overlapping.count
        var out: [TimedValue] = []
        for s in overlapping {
            if s.start > asOf.addingTimeInterval(limits.futureTolerance) { stats.future += 1; continue }
            let d = s.end.timeIntervalSince(s.start)
            guard s.value.isFinite, range.contains(s.value), d >= 0, d <= limits.maxSampleDuration else {
                stats.implausible += 1
                continue
            }
            out.append(s)
        }
        out.sort { ($0.start, $0.end, $0.value) < ($1.start, $1.end, $1.value) }
        let deduped = dedupe(out) { $0.start == $1.start && $0.end == $1.end && $0.value == $1.value }
        stats.duplicates += out.count - deduped.count
        record(deduped.map(\.start), deduped.map(\.end), into: &stats)
        return deduped
    }

    static func heartRate(_ samples: [HRSample], within interval: DateInterval, asOf: Date,
                          limits: PlausibilityLimits, stats: inout InputStats) -> [HRSample] {
        let overlapping = samples.filter { $0.date >= interval.start && $0.date < interval.end }
        stats.received += overlapping.count
        var out: [HRSample] = []
        for s in overlapping {
            if s.date > asOf.addingTimeInterval(limits.futureTolerance) { stats.future += 1; continue }
            guard s.bpm.isFinite, limits.heartRate.contains(s.bpm) else { stats.implausible += 1; continue }
            out.append(s)
        }
        out.sort { ($0.date, $0.bpm) < ($1.date, $1.bpm) }
        let deduped = dedupe(out) { $0.date == $1.date && $0.bpm == $1.bpm }
        stats.duplicates += out.count - deduped.count
        record(deduped.map(\.date), deduped.map(\.date), into: &stats)
        return deduped
    }

    static func sleep(_ segments: [SleepSegment], within interval: DateInterval, asOf: Date,
                      limits: PlausibilityLimits, stats: inout InputStats) -> [SleepSegment] {
        let overlapping = segments.filter { $0.end > interval.start && $0.start < interval.end }
        stats.received += overlapping.count
        var out: [SleepSegment] = []
        for s in overlapping {
            if s.start > asOf.addingTimeInterval(limits.futureTolerance) { stats.future += 1; continue }
            let d = s.end.timeIntervalSince(s.start)
            guard d > 0, d <= limits.maxSampleDuration else { stats.implausible += 1; continue }
            out.append(s)
        }
        out.sort { ($0.start, $0.end, $0.stage.rawValue, $0.sourcePriority) < ($1.start, $1.end, $1.stage.rawValue, $1.sourcePriority) }
        let deduped = dedupe(out) {
            $0.start == $1.start && $0.end == $1.end && $0.stage == $1.stage && $0.sourcePriority == $1.sourcePriority
        }
        stats.duplicates += out.count - deduped.count
        record(deduped.map(\.start), deduped.map(\.end), into: &stats)
        return deduped
    }

    static func workouts(_ workouts: [WorkoutSample], within interval: DateInterval, asOf: Date,
                         limits: PlausibilityLimits, stats: inout InputStats) -> [WorkoutSample] {
        let overlapping = workouts.filter { $0.end >= interval.start && $0.start < interval.end }
        stats.received += overlapping.count
        var out: [WorkoutSample] = []
        for w in overlapping {
            if w.start > asOf.addingTimeInterval(limits.futureTolerance) { stats.future += 1; continue }
            let d = w.end.timeIntervalSince(w.start)
            guard d > 0, d <= limits.maxSampleDuration else { stats.implausible += 1; continue }
            out.append(w)
        }
        out.sort { ($0.start, $0.end, $0.activityType) < ($1.start, $1.end, $1.activityType) }
        let deduped = dedupe(out) { $0.start == $1.start && $0.end == $1.end }
        stats.duplicates += out.count - deduped.count
        record(deduped.map(\.start), deduped.map(\.end), into: &stats)
        return deduped
    }

    /// Removes adjacent elements considered equal; input must be sorted.
    static func dedupe<T>(_ sorted: [T], _ same: (T, T) -> Bool) -> [T] {
        var out: [T] = []
        out.reserveCapacity(sorted.count)
        for x in sorted where !(out.last.map { same($0, x) } ?? false) {
            out.append(x)
        }
        return out
    }

    private static func record(_ starts: [Date], _ ends: [Date], into stats: inout InputStats) {
        stats.accepted += starts.count
        if let first = starts.min() { stats.earliest = min(stats.earliest ?? first, first) }
        if let last = ends.max() { stats.latest = max(stats.latest ?? last, last) }
    }
}

/// Deterministic 64-bit FNV-1a. Swift's `Hasher` is randomly seeded per
/// process, so it must never be used for anything persisted.
public struct FNV1a: Sendable {
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    public mutating func add(_ x: UInt64) {
        var v = x
        for _ in 0..<8 {
            value ^= v & 0xff
            value = value &* 0x0000_0100_0000_01b3
            v >>= 8
        }
    }

    public mutating func add(_ d: Double) { add(d.bitPattern) }
    public mutating func add(_ d: Date) { add(d.timeIntervalSinceReferenceDate) }
    public mutating func add(_ i: Int) { add(UInt64(bitPattern: Int64(i))) }

    public var hex: String { String(format: "%016llx", value) }
}

public enum SourceFingerprint {
    /// Fingerprint of every non-heart-rate input that can affect `windows`'
    /// day. A change means HealthKit data for that day was added, corrected,
    /// deleted or hidden (e.g. a revoked permission), so the day is rebuilt.
    public static func compute(windows: DayWindows, input: RawDayInput, asOf: Date,
                               limits: PlausibilityLimits = PlausibilityLimits()) -> String {
        let interval = windows.union
        var scratch = InputStats()
        var h = FNV1a()
        func tag(_ t: Int) { h.add(UInt64(t) << 56) }

        tag(1)
        for s in Sanitizer.sleep(input.sleep, within: interval, asOf: asOf, limits: limits, stats: &scratch) {
            h.add(s.start); h.add(s.end); h.add(s.stage.rawValue); h.add(s.sourcePriority)
        }
        let timed: [(Int, [TimedValue], ClosedRange<Double>)] = [
            (2, input.hrv, limits.hrvSDNN),
            (3, input.restingHR, limits.restingHR),
            (4, input.respiratoryRate, limits.respiratoryRate),
            (5, input.wristTemperature, limits.wristTemperature),
            (7, input.heartRateRecovery, limits.heartRateRecovery),
        ]
        for (t, samples, range) in timed {
            tag(t)
            for s in Sanitizer.timed(samples, range: range, within: interval, asOf: asOf, limits: limits, stats: &scratch) {
                h.add(s.start); h.add(s.end); h.add(s.value)
            }
        }
        tag(6)
        for w in Sanitizer.workouts(input.workouts, within: interval, asOf: asOf, limits: limits, stats: &scratch) {
            h.add(w.start); h.add(w.end); h.add(Int(w.activityType))
        }
        return h.hex
    }
}
