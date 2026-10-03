import Foundation

public enum Sex: String, Codable, Sendable, CaseIterable {
    case male, female, unspecified
}

/// User-editable inputs. Everything else lives in `ModelParameters`.
public struct UserSettings: Codable, Sendable, Equatable {
    /// Measured max HR. When nil, Tanaka (208 - 0.7 * age) is used, then 190.
    public var hrMaxOverride: Double?
    public var age: Int?
    public var sex: Sex
    public var baseSleepNeedHours: Double
    /// Today's load is capped so that ATL/CTL stays at or below this ratio.
    public var acwrCeiling: Double

    public init(hrMaxOverride: Double? = nil,
                age: Int? = nil,
                sex: Sex = .unspecified,
                baseSleepNeedHours: Double = 8.0,
                acwrCeiling: Double = 1.3) {
        self.hrMaxOverride = hrMaxOverride
        self.age = age
        self.sex = sex
        self.baseSleepNeedHours = baseSleepNeedHours
        self.acwrCeiling = acwrCeiling
    }

    public var resolvedHRMax: Double {
        if let h = hrMaxOverride, h > 100 { return h }
        if let a = age, a > 0 { return 208 - 0.7 * Double(a) }
        return 190
    }
}

/// Every model constant in one place. Values are documented in docs/METHODOLOGY.md.
public struct ModelParameters: Sendable, Equatable {
    // Baselines
    public var baselineWindowDays = 60
    public var minBaselineDays = 14
    public var highConfidenceBaselineDays = 30
    public var hrvScaleFloor = 0.05          // ln(ms)
    public var restingHRScaleFloor = 1.0     // bpm
    public var respiratoryScaleFloor = 0.3   // breaths/min
    public var temperatureScaleFloor = 0.1   // degC

    // Recovery weights (renormalised over available components)
    public var weightHRV = 0.45
    public var weightRestingHR = 0.25
    public var weightSleep = 0.15
    public var weightRespiratory = 0.075
    public var weightTemperature = 0.075
    public var zClamp = 3.0
    /// Respiratory rate and temperature only penalise beyond this many robust SDs.
    public var asymmetricDeadband = 1.0
    /// Sleep performance shortfall equivalent to -1 SD.
    public var sleepShortfallPerSD = 0.15
    public var primedThreshold = 67
    public var depletedThreshold = 33
    /// Score at or below which "recover" is issued without confirmation.
    public var recoverScore = 15
    public var minCalibrationDays = 20
    public var compositeScaleFloor = 0.05

    // Flags
    /// Elevated-overnight-vitals threshold (sleeping HR and temp or respiration).
    public var elevatedVitalsZ = 2.0
    public var hrvTrendDays = 7
    public var hrvTrendMinDays = 4
    /// Smallest-worthwhile-change band: baseline +/- this many robust SDs.
    public var hrvTrendSWC = 0.5
    public var loadSpikeACWR = 1.5
    public var sleepDebtFlagHours = 5.0

    // Sleep
    public var sleepBoutMergeGap: TimeInterval = 90 * 60
    public var minSleepHRSamples = 10
    public var sleepingHRQuantile = 0.10
    public var sleepDebtNights = 7
    public var sleepDebtRepayFraction = 0.2
    public var sleepDebtRepayCap: TimeInterval = 3600
    public var sleepStrainAdjustPerUnitRatio: TimeInterval = 1800
    public var sleepStrainAdjustCap: TimeInterval = 2700
    public var consistencyNights = 7
    public var consistencyMinNights = 4

    // Heart rate / load
    public var maxSampleGap: TimeInterval = 300
    /// Heart-rate reserve below this fraction contributes no training load.
    public var activityFloorHRR = 0.30
    public var minCoverageHours = 2.0
    public var atlDays = 7.0
    public var ctlDays = 42.0
    public var loadSeedDays = 14
    public var minLoadHistoryDays = 28
    public var minCTLForTargets = 10.0

    // Journal impact
    public var minTagSamples = 5
    public var tagAlpha = 0.05

    // Data hygiene
    public var plausibility = PlausibilityLimits()
    /// Today's overnight window counts as closed this long after the main sleep
    /// bout ends (or at the end of the fallback overnight window, whichever is first).
    public var overnightSettleTime: TimeInterval = 30 * 60

    public init() {}

    public static let standard = ModelParameters()
}
