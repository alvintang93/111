import Foundation

/// Metrics with a full detail view: current value, personal baseline, change,
/// trends, history, provenance and an explicit data state.
public enum HealthMetricKind: String, Codable, Sendable, CaseIterable {
    case hrv, sleepingHR, restingHR, respiratoryRate, wristTemperature, spo2
    case sleep, vo2Max, bodyMass, bodyFat, leanMass, hrRecovery, load

    public var title: String {
        switch self {
        case .hrv: return "HRV"
        case .sleepingHR: return "Sleeping HR"
        case .restingHR: return "Resting HR"
        case .respiratoryRate: return "Respiratory rate"
        case .wristTemperature: return "Wrist temperature"
        case .spo2: return "Blood oxygen"
        case .sleep: return "Sleep"
        case .vo2Max: return "VO₂ max"
        case .bodyMass: return "Weight"
        case .bodyFat: return "Body fat"
        case .leanMass: return "Lean mass"
        case .hrRecovery: return "HR recovery"
        case .load: return "Training load"
        }
    }

    public var unit: String {
        switch self {
        case .hrv: return "ms"
        case .sleepingHR, .restingHR: return "bpm"
        case .respiratoryRate: return "/min"
        case .wristTemperature: return "°C"
        case .spo2, .bodyFat: return "%"
        case .sleep: return "h"
        case .vo2Max: return "mL/kg/min"
        case .bodyMass, .leanMass: return "kg"
        case .hrRecovery: return "bpm"
        case .load: return "TRIMP"
        }
    }

    public var digits: Int {
        switch self {
        case .respiratoryRate, .vo2Max, .bodyMass, .bodyFat, .leanMass, .sleep: return 1
        case .wristTemperature: return 2
        default: return 0
        }
    }

    /// Direction that reads as favourable for you. Nil when neither direction is better in general.
    public var higherIsBetter: Bool? {
        switch self {
        case .hrv, .vo2Max, .hrRecovery, .sleep, .leanMass: return true
        case .sleepingHR, .restingHR: return false
        case .respiratoryRate, .wristTemperature, .spo2, .bodyMass, .bodyFat, .load: return nil
        }
    }

    /// Recovery inputs. Displayed values for these reconcile exactly with the score.
    public var usedByRecovery: Bool {
        switch self {
        case .hrv, .sleepingHR, .respiratoryRate, .wristTemperature, .sleep: return true
        default: return false
        }
    }

    /// Older than this, the latest value is "stale".
    public var staleAfterDays: Int {
        switch self {
        case .hrv, .sleepingHR, .respiratoryRate, .wristTemperature, .sleep, .restingHR, .load: return 1
        case .spo2: return 3
        case .bodyMass, .bodyFat, .leanMass, .hrRecovery: return 14
        case .vo2Max: return 60
        }
    }

    /// Trend windows shown for this metric.
    public var trendWindows: [Int] {
        switch self {
        case .vo2Max: return [30, 60, 90]
        case .bodyMass, .bodyFat, .leanMass: return [7, 30, 90]
        default: return [7, 30, 60]
        }
    }

    /// Nightly/daily metrics have a 60-day median/MAD baseline; sporadic ones are compared with earlier readings.
    public var hasRollingBaseline: Bool {
        switch self {
        case .vo2Max, .bodyMass, .bodyFat, .leanMass: return false
        default: return true
        }
    }
}

public enum MetricDataState: String, Codable, Sendable {
    /// Current value present and fresh; baseline available where applicable.
    case available
    /// A value exists but is older than the metric's freshness limit.
    case stale
    /// A current value exists, but there isn't enough history for a baseline or trend.
    case insufficientHistory
    /// No accepted measurement in the history window.
    case noMeasurement
    /// Health permission prompt not answered yet: nothing can be read.
    case notAuthorized
    /// The last Health read for this input failed; cached values (if any) are shown.
    case readFailed
}

public struct MetricObservation: Codable, Sendable, Equatable, Identifiable {
    public var date: Date
    /// The Margin day this observation belongs to (stored day windows, so time-zone changes don't move it).
    public var day: Day
    public var value: Double
    public var source: String?
    /// Samples behind this value (e.g. overnight HRV readings), when it aggregates several.
    public var count: Int?
    public var note: String?
    public var id: String { "\(date.timeIntervalSinceReferenceDate)-\(value)" }

    public init(date: Date, day: Day, value: Double, source: String? = nil, count: Int? = nil, note: String? = nil) {
        self.date = date
        self.day = day
        self.value = value
        self.source = source
        self.count = count
        self.note = note
    }
}

public struct MetricBaseline: Codable, Sendable, Equatable {
    /// Display units.
    public var center: Double
    /// Robust SD in the units the z-score uses (ln ms for HRV).
    public var scale: Double
    public var count: Int
    public var windowDays: Int
    public var method: String
}

public struct TrendWindow: Codable, Sendable, Equatable, Identifiable {
    public var days: Int
    public var n: Int
    public var mean: Double?
    /// Theil-Sen slope; nil when insufficient.
    public var slopePerWeek: Double?
    /// Change between the latest value and the value at the start of the window
    /// (nearest observation on or before it).
    public var change: Double?
    public var sufficient: Bool
    public var id: Int { days }
}

public struct MetricReport: Codable, Sendable, Equatable, Identifiable {
    public var kind: HealthMetricKind
    public var state: MetricDataState
    public var stateDetail: String
    public var current: MetricObservation?
    public var previous: MetricObservation?
    public var baseline: MetricBaseline?
    /// current − baseline (display units).
    public var deltaFromBaseline: Double?
    /// For HRV, the percent change implied by the ln-space difference.
    public var deltaPercent: Double?
    /// Robust z vs the baseline (same as the recovery component's raw z for score inputs).
    public var z: Double?
    public var trends: [TrendWindow]
    /// Daily (or per-reading) history, oldest first.
    public var history: [MetricObservation]
    /// The individual readings behind the current value (e.g. last night's HRV samples), oldest first.
    public var readings: [MetricObservation]
    public var sources: [String]
    public var notes: [String]
    public var methodology: String
    public var id: String { kind.rawValue }
}

public enum MetricMath {
    /// Value at or before `date`, within `tolerance`; for "change vs N days ago".
    public static func value(onOrBefore date: Date, in obs: [MetricObservation], tolerance: TimeInterval) -> MetricObservation? {
        obs.last { $0.date <= date && date.timeIntervalSince($0.date) <= tolerance }
    }

    /// Minimum observations for a trend in a window of `days`.
    public static func minimumCount(days: Int, sporadic: Bool) -> Int {
        if sporadic { return 3 }
        switch days {
        case ...7: return 4
        case ...30: return 10
        default: return 15
        }
    }

    public static func trends(_ obs: [MetricObservation], windows: [Int], asOf: Date, sporadic: Bool) -> [TrendWindow] {
        windows.map { days in
            let from = asOf.addingTimeInterval(-Double(days) * 86400)
            let inWindow = obs.filter { $0.date >= from && $0.date <= asOf }
            let need = minimumCount(days: days, sporadic: sporadic)
            let sufficient = inWindow.count >= need
            var slope: Double?
            if sufficient {
                let series = inWindow.map { TimedValue(start: $0.date, end: $0.date, value: $0.value) }
                slope = TrendModel.fit(series, asOf: asOf, windowDays: Double(days), minCount: need,
                                       minSpanDays: min(Double(days) / 2, 14))?.slopePerWeek
            }
            var change: Double?
            if let last = inWindow.last, let start = value(onOrBefore: from, in: obs, tolerance: Double(days) * 86400 / 2)
                ?? inWindow.first.flatMap({ $0.date < last.date ? $0 : nil }) {
                change = last.value - start.value
            }
            return TrendWindow(days: days, n: inWindow.count, mean: Stats.mean(inWindow.map(\.value)), slopePerWeek: slope,
                               change: sufficient ? change : nil, sufficient: sufficient)
        }
    }
}
