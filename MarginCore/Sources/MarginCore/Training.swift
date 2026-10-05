import Foundation

// MARK: - Custom heart-rate zones

public enum ZoneMode: String, Codable, Sendable, CaseIterable {
    /// Percent of heart-rate reserve (HRrest to HRmax).
    case reserve
    /// Percent of HRmax.
    case maxHR
    /// Fixed bpm.
    case bpm
}

/// Lower bounds of zones 1-5 (ascending). Time below zone 1 is "zone 0".
public struct ZoneSettings: Codable, Sendable, Equatable {
    public var mode: ZoneMode
    public var lowerBounds: [Double]

    public init(mode: ZoneMode = .reserve, lowerBounds: [Double] = [50, 60, 70, 80, 90]) {
        self.mode = mode
        self.lowerBounds = lowerBounds
    }

    public static let standard = ZoneSettings()

    /// Defaults for each mode, used when switching modes.
    public static func defaults(for mode: ZoneMode) -> ZoneSettings {
        switch mode {
        case .reserve: return ZoneSettings(mode: .reserve, lowerBounds: [50, 60, 70, 80, 90])
        case .maxHR: return ZoneSettings(mode: .maxHR, lowerBounds: [50, 60, 70, 80, 90])
        case .bpm: return ZoneSettings(mode: .bpm, lowerBounds: [110, 130, 145, 160, 175])
        }
    }

    /// Valid when there are exactly 5 strictly ascending, positive bounds.
    public var isValid: Bool {
        lowerBounds.count == 5 && lowerBounds.allSatisfy { $0 > 0 } && zip(lowerBounds, lowerBounds.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// Zone lower bounds in bpm. Falls back to the standard zones if invalid.
    public func bpmBounds(hrRest: Double, hrMax: Double) -> [Double] {
        let s = isValid ? self : .standard
        switch s.mode {
        case .reserve: return s.lowerBounds.map { hrRest + $0 / 100 * (hrMax - hrRest) }
        case .maxHR: return s.lowerBounds.map { $0 / 100 * hrMax }
        case .bpm: return s.lowerBounds
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(ZoneMode.self, forKey: .mode)) ?? .reserve
        lowerBounds = (try? c.decodeIfPresent([Double].self, forKey: .lowerBounds)) ?? ZoneSettings.defaults(for: mode).lowerBounds
    }
}

public enum ZoneModel {
    /// Seconds in zones 0-5 from time at each bpm.
    public static func zoneSeconds(bpmSeconds: [Int: Double], bounds: [Double]) -> [Double] {
        var out = Array(repeating: 0.0, count: 6)
        for bpm in bpmSeconds.keys.sorted() {
            let z = bounds.lastIndex { Double(bpm) >= $0 }.map { $0 + 1 } ?? 0
            out[z] += bpmSeconds[bpm]!
        }
        return out
    }

    public static func zoneSeconds(histogram: HeartRateHistogram, bounds: [Double]) -> [Double] {
        var bins: [Int: Double] = [:]
        for (bpm, s) in histogram.seconds.enumerated() where s > 0 { bins[bpm] = s }
        return zoneSeconds(bpmSeconds: bins, bounds: bounds)
    }
}

// MARK: - Cardio focus

public enum CardioFocus: String, Codable, Sendable, CaseIterable {
    /// Mostly zones 1-2.
    case lowAerobic
    /// Mostly zones 3-4.
    case highAerobic
    /// Meaningful time in zone 5.
    case anaerobic

    /// Rules: anaerobic if zone 5 holds at least 10% of in-zone time and 3 min;
    /// otherwise high aerobic if zones 3-4 hold at least 40% of in-zone time;
    /// otherwise low aerobic. Nil with under 5 min in zones 1-5.
    public static func classify(zoneSeconds z: [Double]) -> CardioFocus? {
        guard z.count == 6 else { return nil }
        let low = z[1] + z[2], high = z[3] + z[4], top = z[5]
        let total = low + high + top
        guard total >= 300 else { return nil }
        if top >= 180 && top / total >= 0.10 { return .anaerobic }
        if high / total >= 0.40 { return .highAerobic }
        return .lowAerobic
    }

    /// Index into the 3-group minutes array.
    public var index: Int { CardioFocus.allCases.firstIndex(of: self)! }
}

public struct WorkoutFocus: Codable, Sendable, Equatable, Identifiable {
    public var start: Date
    public var activityType: UInt
    public var minutes: Double
    /// Minutes in zones 0-5.
    public var zoneMinutes: [Double]
    public var focus: CardioFocus?
    public var id: Date { start }
}

public struct CardioFocusSummary: Codable, Sendable, Equatable {
    /// Workout minutes in low aerobic (z1-2), high aerobic (z3-4) and anaerobic (z5) over 28 days.
    public var minutes28d: [Double]
    public var workouts: [WorkoutFocus]
    /// Zone lower bounds in bpm used for every number here.
    public var bounds: [Double]
}

// MARK: - Compare two metrics

public enum CompareMetric: String, Codable, Sendable, CaseIterable {
    case recovery, hrv, sleepingHR, sleepHours, sleepScore, load, stress, steps, caffeine, water

    public var title: String {
        switch self {
        case .recovery: return "Recovery"
        case .hrv: return "HRV"
        case .sleepingHR: return "Sleeping HR"
        case .sleepHours: return "Sleep hours"
        case .sleepScore: return "Sleep score"
        case .load: return "Load"
        case .stress: return "Stress"
        case .steps: return "Steps"
        case .caffeine: return "Caffeine"
        case .water: return "Water"
        }
    }
}

public struct MetricSeries: Codable, Sendable, Equatable, Identifiable {
    public var metric: CompareMetric
    public var points: [DayValue]
    public var id: String { metric.rawValue }
}

public struct CorrelationResult: Codable, Sendable, Equatable {
    public var rho: Double
    public var n: Int
    /// Two-sided p-value (t approximation, n - 2 degrees of freedom).
    public var pValue: Double?
}

public enum Correlation {
    /// Average ranks (ties share the mean rank).
    static func ranks(_ xs: [Double]) -> [Double] {
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        var r = Array(repeating: 0.0, count: xs.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && xs[order[j + 1]] == xs[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3, let mx = Stats.mean(x), let my = Stats.mean(y) else { return nil }
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    public static func spearman(_ x: [Double], _ y: [Double]) -> CorrelationResult? {
        guard let rho = pearson(ranks(x), ranks(y)) else { return nil }
        let n = x.count
        var p: Double?
        if n >= 4 {
            let r = Stats.clamp(rho, -0.999999, 0.999999)
            p = Stats.studentTTwoSidedP(t: r * (Double(n - 2) / (1 - r * r)).squareRoot(), df: Double(n - 2))
        }
        return CorrelationResult(rho: rho, n: n, pValue: p)
    }

    /// Pairs `a` on day D with `b` on day D + lag (lag 1: does today's A go with tomorrow's B?).
    public static func pairs(_ a: MetricSeries, _ b: MetricSeries, lagDays: Int,
                             calendar: Calendar) -> [(day: Day, x: Double, y: Double)] {
        let bByDay = Dictionary(b.points.map { ($0.day, $0.value) }, uniquingKeysWith: { x, _ in x })
        return a.points.compactMap { p in
            bByDay[p.day.adding(lagDays, calendar: calendar)].map { (p.day, p.value, $0) }
        }
    }
}

// MARK: - Smart alarm

public struct SmartAlarmSettings: Codable, Sendable, Equatable {
    public var enabled = false
    /// Latest wake time, minutes after midnight.
    public var wakeMinutes = 7 * 60
    /// The alarm may go off this many minutes early, at the first sign of light sleep.
    public var windowMinutes = 20

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        wakeMinutes = (try? c.decodeIfPresent(Int.self, forKey: .wakeMinutes)) ?? 7 * 60
        windowMinutes = (try? c.decodeIfPresent(Int.self, forKey: .windowMinutes)) ?? 20
    }

    /// Next window start and latest wake time after `now`.
    public func nextWindow(after now: Date, calendar: Calendar) -> (start: Date, wake: Date) {
        let midnight = calendar.startOfDay(for: now)
        var wake = midnight.addingTimeInterval(TimeInterval(wakeMinutes * 60))
        let window = TimeInterval(max(0, min(windowMinutes, 30)) * 60)
        if wake.addingTimeInterval(-window) <= now { wake = calendar.date(byAdding: .day, value: 1, to: wake)! }
        return (wake.addingTimeInterval(-window), wake)
    }
}

/// Decides when to wake inside the window from wrist motion. Light sleep and
/// brief arousals come with movement, deep sleep with stillness, so the alarm
/// fires at the first sustained movement or at the latest wake time.
public struct SmartAlarmDetector: Sendable {
    /// Mean |acceleration − 1 g| over an epoch above this (g) counts as movement.
    public var movementThreshold = 0.015
    /// Consecutive moving epochs needed.
    public var epochsNeeded = 2
    public private(set) var consecutive = 0
    public private(set) var epochs = 0

    public init(movementThreshold: Double = 0.015, epochsNeeded: Int = 2) {
        self.movementThreshold = movementThreshold
        self.epochsNeeded = epochsNeeded
    }

    /// Feed one epoch (typically 30 s) of acceleration magnitudes in g. Returns true when it is time to wake.
    public mutating func add(epoch magnitudes: [Double]) -> Bool {
        epochs += 1
        guard !magnitudes.isEmpty else { consecutive = 0; return false }
        let activity = magnitudes.reduce(0) { $0 + abs($1 - 1) } / Double(magnitudes.count)
        consecutive = activity >= movementThreshold ? consecutive + 1 : 0
        return consecutive >= epochsNeeded
    }
}
