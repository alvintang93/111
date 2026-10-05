import Foundation

// MARK: - Strain

public struct StrainSummary: Codable, Sendable, Equatable {
    public enum Reference: String, Codable, Sendable {
        /// Your 42-day chronic load (CTL): 50 = a typical day for you.
        case chronicLoad
        /// Fixed reference while chronic load is not yet eligible.
        case provisional
    }

    /// 0...100. Nil when today's heart rate covers too little of the day.
    public var score: Int?
    public var load: Double?
    /// TRIMP that maps to strain 50.
    public var referenceLoad: Double
    public var reference: Reference
    /// Today's recommended load range, on the strain scale.
    public var targetLow: Int?
    public var targetHigh: Int?
    /// Load per hour of the activity window (hour index, TRIMP), scaled to the day's exact total.
    public var hourly: [HourValue]
}

public struct HourValue: Codable, Sendable, Equatable, Identifiable {
    public var hour: Int
    public var start: Date
    public var value: Double
    public var id: Int { hour }
}

public enum StrainModel {
    /// Saturating map from load to 0...100: a load equal to the reference is
    /// 50, and each further reference halves the distance left to 100.
    public static func score(load: Double, reference: Double) -> Double {
        guard reference > 0, load > 0 else { return 0 }
        return 100 * (1 - pow(2, -load / reference))
    }
}

// MARK: - Stress

public enum StressBand: String, Codable, Sendable, CaseIterable {
    case rest, low, medium, high

    public init(level: Int) {
        switch level {
        case ...25: self = .rest
        case ...50: self = .low
        case ...75: self = .medium
        default: self = .high
        }
    }
}

public struct StressHour: Codable, Sendable, Equatable, Identifiable {
    public var hour: Int
    public var start: Date
    /// Nil when the hour has too little rest-state heart rate.
    public var level: Int?
    public var restMinutes: Double
    public var id: Int { hour }
}

public struct StressSummary: Codable, Sendable, Equatable {
    /// Rest-time-weighted mean of hourly levels, 0...100.
    public var score: Int?
    /// Latest hour with a level.
    public var current: Int?
    public var currentAt: Date?
    public var hours: [StressHour]
    /// Rest-state minutes in rest / low / medium / high bands (hour resolution).
    public var bandMinutes: [Double]
    public var restMinutes: Double
    /// HRrest the levels are measured from.
    public var referenceHR: Double
}

public enum StressModel {
    /// Stress from rest-state heart rate: 0 at HRrest, 100 at
    /// `stressFullScaleHRR` of heart-rate reserve above it.
    public static func level(meanBPM: Double, hrRest: Double, hrMax: Double, params: ModelParameters) -> Int {
        let span = params.stressFullScaleHRR * max(hrMax - hrRest, 20)
        return Int((100 * Stats.clamp((meanBPM - hrRest) / span, 0, 1)).rounded())
    }

    public static func summarize(slices: [HourSlice], windowStart: Date, hrRest: Double, hrMax: Double,
                                 params: ModelParameters) -> StressSummary {
        var hours: [StressHour] = []
        var bands = Array(repeating: 0.0, count: StressBand.allCases.count)
        var weighted = 0.0, weight = 0.0, totalRest = 0.0
        for s in slices.sorted(by: { $0.hour < $1.hour }) where s.restSeconds > 0 {
            let start = windowStart.addingTimeInterval(Double(s.hour) * 3600)
            totalRest += s.restSeconds
            var hourLevel: Int?
            if s.restSeconds >= params.minStressRestSeconds, let m = s.restMeanBPM {
                let l = level(meanBPM: m, hrRest: hrRest, hrMax: hrMax, params: params)
                hourLevel = l
                weighted += Double(l) * s.restSeconds
                weight += s.restSeconds
                bands[StressBand.allCases.firstIndex(of: StressBand(level: l))!] += s.restSeconds / 60
            }
            hours.append(StressHour(hour: s.hour, start: start, level: hourLevel, restMinutes: s.restSeconds / 60))
        }
        let latest = hours.last { $0.level != nil }
        let score = weight >= params.minDailyStressRestSeconds ? Int((weighted / weight).rounded()) : nil
        return StressSummary(score: score, current: latest?.level, currentAt: latest?.start, hours: hours,
                             bandMinutes: bands, restMinutes: totalRest / 60, referenceHR: hrRest)
    }
}

// MARK: - Energy bank

public struct EnergyPoint: Codable, Sendable, Equatable, Identifiable {
    public var date: Date
    public var level: Double
    public var id: Date { date }
}

public struct EnergySummary: Codable, Sendable, Equatable {
    public enum StartSource: String, Codable, Sendable {
        case recoveryAndSleep, recovery, sleep
    }

    /// 0...100 now (as of the last sync).
    public var current: Int
    /// Level at wake.
    public var start: Int
    public var startedAt: Date
    public var startSource: StartSource
    public var low: Int
    public var points: [EnergyPoint]
    public var drainedByStrain: Double
    public var drainedByStress: Double
    public var drainedByWaking: Double
    public var chargedByRest: Double
    public var chargedByNaps: Double
}

public enum EnergyModel {
    /// Morning level from the recovery score and sleep score. Nil without either.
    public static func startLevel(recovery: Int?, sleepScore: Int?,
                                  params: ModelParameters) -> (Double, EnergySummary.StartSource)? {
        switch (recovery, sleepScore) {
        case let (r?, s?):
            let w = params.energyRecoveryWeight
            return (w * Double(r) + (1 - w) * Double(s), .recoveryAndSleep)
        case let (r?, nil):
            return (Double(r), .recovery)
        case let (nil, s?):
            // Without overnight physiology the sleep score alone cannot reach the extremes.
            return (20 + 0.7 * Double(s), .sleep)
        case (nil, nil):
            return nil
        }
    }

    /// Hour-by-hour simulation from wake until `asOf`. Drains: being awake,
    /// load (TRIMP relative to the strain reference) and rest-state stress
    /// above 50. Charges: rest-state time at stress 25 or below, and naps.
    public static func run(start: Double, source: EnergySummary.StartSource, wake: Date, asOf: Date,
                           windowStart: Date, slices: [HourSlice], hourlyLoad: [Int: Double], referenceLoad: Double,
                           stressLevels: [Int: Int], params: ModelParameters) -> EnergySummary? {
        guard asOf > wake else { return nil }
        let byHour = Dictionary(slices.map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        var level = Stats.clamp(start, 0, 100)
        var points = [EnergyPoint(date: wake, level: level)]
        var low = level
        var strain = 0.0, stress = 0.0, waking = 0.0, rest = 0.0, naps = 0.0
        let firstHour = max(0, Int(floor(wake.timeIntervalSince(windowStart) / 3600)))
        let lastHour = Int(floor(asOf.timeIntervalSince(windowStart) / 3600))
        guard lastHour >= firstHour else { return nil }
        for h in firstHour...lastHour {
            let hs = windowStart.addingTimeInterval(Double(h) * 3600)
            let a = max(hs, wake), b = min(hs.addingTimeInterval(3600), asOf)
            let frac = b.timeIntervalSince(a) / 3600
            guard frac > 0 else { continue }
            let s = byHour[h]
            let napHours = h > firstHour ? (s?.asleepSeconds ?? 0) / 3600 : 0
            let awakeHours = max(frac - napHours, 0)
            let restHours = (s?.restSeconds ?? 0) / 3600
            let dWake = params.energyAwakeDrainPerHour * awakeHours
            let dStrain = referenceLoad > 0 ? (hourlyLoad[h] ?? 0) / referenceLoad * params.energyStrainDrainPerReference : 0
            var dStress = 0.0, cRest = 0.0
            if let l = stressLevels[h] {
                if l > 50 { dStress = Double(l - 50) / 50 * params.energyStressDrainPerHour * restHours }
                if l <= 25 { cRest = params.energyRestChargePerHour * restHours }
            }
            let cNap = params.energyNapChargePerHour * napHours
            level = Stats.clamp(level - dWake - dStrain - dStress + cRest + cNap, 0, 100)
            waking += dWake; strain += dStrain; stress += dStress; rest += cRest; naps += cNap
            low = min(low, level)
            points.append(EnergyPoint(date: b, level: level))
        }
        return EnergySummary(current: Int(level.rounded()), start: Int(Stats.clamp(start, 0, 100).rounded()),
                             startedAt: wake, startSource: source, low: Int(low.rounded()), points: points,
                             drainedByStrain: strain, drainedByStress: stress, drainedByWaking: waking,
                             chargedByRest: rest, chargedByNaps: naps)
    }
}

// MARK: - Heart-rate recovery

public struct HeartRateRecoveryPoint: Codable, Sendable, Equatable, Identifiable {
    public var day: Day
    public var start: Date
    public var activityType: UInt
    /// bpm drop in the first minute after the workout.
    public var drop: Double
    public var id: Date { start }
}

public struct HeartRateRecoverySummary: Codable, Sendable, Equatable {
    public var latest: WorkoutDetail?
    public var latestDay: Day?
    /// Median one-minute drop over the baseline window, excluding the newest measured workout.
    public var typicalDrop: Double?
    /// Most recent workouts with a one-minute drop, oldest first. The last one is the newest measurement.
    public var recent: [HeartRateRecoveryPoint]
}
