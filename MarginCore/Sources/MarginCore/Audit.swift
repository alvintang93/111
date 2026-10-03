import Foundation

/// Per-input data availability, aggregated from the same records the engine scores.
public struct InputAvailability: Codable, Sendable, Equatable, Identifiable {
    public var input: HealthInput
    /// Days (of the last 7, including today) with at least one accepted sample.
    public var daysWithDataLast7: Int
    /// Days in the audit window with at least one accepted sample.
    public var daysWithDataInWindow: Int
    public var windowDays: Int
    public var accepted: Int
    public var duplicates: Int
    public var implausible: Int
    public var future: Int
    public var earliestSample: Date?
    public var latestSample: Date?
    public var id: String { input.rawValue }
}

public struct BaselineSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var kind: ComponentKind
    /// Display units (ms for HRV, bpm, breaths/min, degC).
    public var center: Double
    /// Robust SD in model units (ln-ms for HRV).
    public var scale: Double
    public var count: Int
    public var id: String { kind.rawValue }
}

public struct WeightSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var kind: ComponentKind
    public var weight: Double
    public var id: String { kind.rawValue }
}

public struct ThresholdSnapshot: Codable, Sendable, Equatable {
    public var primedScore: Int
    public var depletedScore: Int
    public var recoverScore: Int
    public var elevatedVitalsZ: Double
    public var hrvTrendSWC: Double
    public var loadSpikeACWR: Double
    public var sleepDebtHours: Double
    public var minHRVNights: Int
    public var minCompositeDays: Int
    public var baselineWindowDays: Int
    public var acwrCeiling: Double
    public var weights: [WeightSnapshot]
}

public struct ComponentStats: Codable, Sendable, Equatable, Identifiable {
    public var kind: ComponentKind
    public var n: Int
    /// Statistics of the oriented, clamped z used in the composite.
    public var mean: Double?
    public var sd: Double?
    public var min: Double?
    public var max: Double?
    public var id: String { kind.rawValue }
}

public struct CountEntry: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var count: Int
    public var id: String { key }
}

/// Recomputed over the audit window with the current records and rules, so
/// threshold behaviour can be inspected. Nothing here changes a threshold.
public struct DecisionDistribution: Codable, Sendable, Equatable {
    public var from: Day?
    public var to: Day?
    public var days: Int
    /// Directive counts in `Directive.allCases` order.
    public var directives: [CountEntry]
    /// Score-status counts in `ScoreStatus.allCases` order.
    public var statuses: [CountEntry]
    /// Ten bins: 0-9, 10-19, ... 90-99.
    public var scoreHistogram: [Int]
    public var scoreMean: Double?
    public var scoreSD: Double?
    public var components: [ComponentStats]

    public func count(_ d: Directive) -> Int { directives.first { $0.key == d.rawValue }?.count ?? 0 }
}

public struct BriefAudit: Codable, Sendable, Equatable {
    public var asOf: Date?
    public var recordCount: Int
    public var earliestRecordDay: Day?
    public var latestRecordDay: Day?
    public var inputs: [InputAvailability]
    public var baselines: [BaselineSnapshot]
    public var thresholds: ThresholdSnapshot
    public var hrMaxSource: String
    public var hrRestSource: String
    public var workoutsLast7: Int
    public var workoutsLast28: Int
    public var latestWorkoutEnd: Date?
    /// Mean heart-rate coverage of workout time over the last 7 days.
    public var workoutHRCoverageLast7: Double?
    /// Distinct time zones the last 14 days were built in (more than one = travel).
    public var recentTimeZones: [String]
    public var distribution: DecisionDistribution

    public func input(_ i: HealthInput) -> InputAvailability? { inputs.first { $0.input == i } }
}
