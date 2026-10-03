import Foundation

public enum RecoveryBand: String, Codable, Sendable {
    case primed, steady, depleted, unknown
}

public enum Confidence: String, Codable, Sendable {
    /// Fewer than `minBaselineDays` of personal history: no score is shown.
    case calibrating
    /// Baseline exists but last night's HRV and sleeping HR are both missing.
    case noData
    case low, medium, high
}

public enum ComponentKind: String, Codable, Sendable, CaseIterable {
    case hrv, restingHR, sleep, respiratoryRate, wristTemperature
}

public struct Component: Codable, Sendable, Equatable, Identifiable {
    public var kind: ComponentKind
    /// Display units: ms, bpm, % of need, breaths/min, degC.
    public var value: Double
    public var baseline: Double?
    /// Oriented so that positive is better, clamped.
    public var z: Double
    /// Raw (unoriented, unclamped) robust z vs baseline; nil for sleep.
    public var rawZ: Double?
    /// Effective weight after renormalising over available components.
    public var weight: Double

    public var contribution: Double { weight * z }
    public var id: String { kind.rawValue }
}

public enum Flag: String, Codable, Sendable, CaseIterable {
    /// Sleeping HR >= +2 SD AND (wrist temp or respiratory rate >= +2 SD).
    /// A measurement pattern, not a diagnosis of any condition.
    case elevatedVitals
    /// 7-day mean ln HRV below baseline minus the smallest worthwhile change.
    case hrvTrendLow
    /// ATL/CTL above the spike threshold.
    case loadSpike
    case sleepDebt
}

public struct Recovery: Codable, Sendable, Equatable {
    public var score: Int?
    public var band: RecoveryBand
    /// Weighted sum of oriented component z-scores.
    public var composite: Double?
    /// Composite relative to your own recent composites (robust SDs); score = Phi(relativeZ).
    public var relativeZ: Double?
    /// Days of composite history used for calibration (0 = theoretical fallback).
    public var calibrationDays: Int
    public var confidence: Confidence
    public var components: [Component]
    public var flags: [Flag]
    public var baselineDays: Int
    /// Whether a score exists and how trustworthy it is. Explicit, never inferred from nil.
    public var status: ScoreStatus
    public var calibration: CalibrationStatus
    /// Human-readable reason for `status`.
    public var statusDetail: String
    /// Core inputs (HRV, sleeping HR) missing for the scored night.
    public var missingInputs: [ComponentKind]
}

/// Score availability, most severe first. Only `.scored` may produce Push.
public enum ScoreStatus: String, Codable, Sendable, CaseIterable {
    /// No score: the overnight window has not closed yet.
    case nightInProgress
    /// No score: no HRV at all in the baseline window although sleeping HR exists
    /// (HRV permission off, or HRV not being recorded).
    case hrvUnavailable
    /// No score: fewer than the required HRV nights.
    case calibrating
    /// No score: neither HRV nor sleeping HR for the night.
    case noOvernightData
    /// Score shown, but HRV or sleeping HR is missing for the night. Push blocked.
    case degraded
    /// Score shown, but its scale uses the early-history fallback. Push blocked.
    case provisional
    /// Score shown with full inputs and a calibrated scale.
    case scored

    public var hasScore: Bool {
        switch self {
        case .degraded, .provisional, .scored: return true
        case .nightInProgress, .hrvUnavailable, .calibrating, .noOvernightData: return false
        }
    }
}

public struct CalibrationStatus: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        /// HRV nights below the minimum: no score.
        case insufficientHRV
        /// Score available; composite scale still on the theoretical fallback.
        case provisionalScale
        case calibrated
    }

    public var stage: Stage
    /// Nights with HRV in the baseline window (the valid calibration days).
    public var hrvNights: Int
    public var hrvNightsRequired: Int
    public var sleepingHRNights: Int
    /// Prior days with a composite available for score calibration.
    public var compositeDays: Int
    public var compositeDaysRequired: Int
}

/// One step of the recommendation rule chain, recorded in evaluation order.
public struct RuleCheck: Codable, Sendable, Equatable, Identifiable {
    public var rule: String
    public var passed: Bool
    public var detail: String
    public var id: String { rule }
}

public enum Directive: String, Codable, Sendable, CaseIterable {
    case push, maintain, recover, rest, calibrating, noData
    /// Overnight window still open; no recommendation yet.
    case pending

    public var isRecommendation: Bool {
        switch self {
        case .push, .maintain, .recover, .rest: return true
        case .calibrating, .noData, .pending: return false
        }
    }
}

public struct Plan: Codable, Sendable, Equatable {
    public var directive: Directive
    /// Recommended total TRIMP for the day.
    public var targetLow: Double?
    public var targetHigh: Double?
    /// Max load today keeping ATL/CTL at or below the user's ceiling.
    public var ceiling: Double?
    public var reasons: [String]
    /// Every rule evaluated to reach `directive`, in order.
    public var trace: [RuleCheck]
}

public struct SleepSummary: Codable, Sendable, Equatable {
    public var asleepHours: Double
    public var needHours: Double
    public var debtHours: Double
    public var performance: Double
    public var efficiency: Double?
    public var midpointSDMinutes: Double?
    public var score: Int
    public var deepMinutes: Double
    public var remMinutes: Double
    public var coreMinutes: Double
    public var awakeMinutes: Double
    public var unspecifiedMinutes: Double
    public var onset: Date
    public var wake: Date
    /// Estimated need for tonight, using today's load so far.
    public var tonightNeedHours: Double
}

public struct LoadSummary: Codable, Sendable, Equatable {
    public var todayLoad: Double?
    public var todayCoverageHours: Double
    /// Minutes in heart-rate-reserve zones today: <50, 50-60, 60-70, 70-80, 80-90, 90+.
    public var todayZoneMinutes: [Double]
    public var atl: Double?
    public var ctl: Double?
    public var acwr: Double?
    public var tsb: Double?
    public var historyDays: Int
    public var unobservedDaysLast28: Int
}

public struct HistoryPoint: Codable, Sendable, Equatable, Identifiable {
    public var day: Day
    public var recoveryScore: Int?
    public var load: Double?
    public var hrvMs: Double?
    public var ctl: Double?
    public var id: String { day.description }
}

public struct TagImpact: Codable, Sendable, Equatable, Identifiable {
    public var tag: String
    public var nWith: Int
    public var nWithout: Int
    /// Next-night HRV vs baseline, tagged minus untagged, as a percentage.
    public var effectPercent: Double
    public var pValue: Double
    /// Significant after Holm-Bonferroni across all tested tags.
    public var significant: Bool
    public var id: String { tag }
}

public struct DailyBrief: Codable, Sendable, Equatable {
    public var day: Day
    public var generatedAt: Date
    public var recovery: Recovery
    public var sleep: SleepSummary?
    public var load: LoadSummary
    public var plan: Plan
    public var history: [HistoryPoint]
    public var tagImpacts: [TagImpact]
    public var hrMaxUsed: Double
    public var hrRestUsed: Double
    /// Last successful HealthKit sync the records reflect (set by the app).
    public var dataSyncedAt: Date?
    /// Everything the diagnostics screen shows, produced by the same engine pass.
    public var audit: BriefAudit
}
