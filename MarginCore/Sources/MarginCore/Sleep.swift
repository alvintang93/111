import Foundation

/// Mirrors HKCategoryValueSleepAnalysis without importing HealthKit.
public enum SleepStage: Int, Codable, Sendable {
    case inBed, awake, asleepUnspecified, core, deep, rem

    public var isAsleep: Bool {
        switch self {
        case .asleepUnspecified, .core, .deep, .rem: return true
        case .inBed, .awake: return false
        }
    }

    /// When segments overlap, the more specific classification wins.
    var precedence: Int {
        switch self {
        case .deep: return 5
        case .rem: return 4
        case .core: return 3
        case .awake: return 2
        case .asleepUnspecified: return 1
        case .inBed: return 0
        }
    }
}

public struct SleepSegment: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let stage: SleepStage
    /// Higher wins. Only segments from the highest-priority source present in
    /// the window are used, so iPhone + Watch data is never double counted.
    public let sourcePriority: Int

    public init(start: Date, end: Date, stage: SleepStage, sourcePriority: Int = 0) {
        self.start = start
        self.end = end
        self.stage = stage
        self.sourcePriority = sourcePriority
    }
}

public struct StageSpan: Codable, Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    public var id: Date { start }
}

public struct SleepNight: Codable, Sendable, Equatable {
    /// All sleep in the night window (main bout + naps), seconds.
    public var asleep: TimeInterval
    public var awake: TimeInterval
    public var core: TimeInterval
    public var deep: TimeInterval
    public var rem: TimeInterval
    public var unspecified: TimeInterval
    /// Main bout = the cluster of sleep (gaps < merge gap) with the most sleep.
    public var mainOnset: Date
    public var mainWake: Date
    public var mainAsleep: TimeInterval
    /// The night's stage timeline (hypnogram), after overlap resolution. Nil in records built before schema 6.
    public var stages: [StageSpan]? = nil

    public var mainSpan: TimeInterval { mainWake.timeIntervalSince(mainOnset) }

    /// Main-bout sleep / main-bout span (onset to final wake).
    public var efficiency: Double? {
        mainSpan > 0 ? min(mainAsleep / mainSpan, 1) : nil
    }

    public var mainMidpoint: Date {
        mainOnset.addingTimeInterval(mainSpan / 2)
    }
}

public enum SleepAggregator {
    /// Builds one night from raw segments. Returns nil when no sleep is found.
    public static func aggregate(segments: [SleepSegment],
                                 window: DateInterval,
                                 boutMergeGap: TimeInterval) -> SleepNight? {
        let clipped: [SleepSegment] = segments.compactMap { s in
            let start = max(s.start, window.start)
            let end = min(s.end, window.end)
            guard end > start else { return nil }
            return SleepSegment(start: start, end: end, stage: s.stage, sourcePriority: s.sourcePriority)
        }
        guard let topPriority = clipped.map(\.sourcePriority).max() else { return nil }
        let chosen = clipped.filter { $0.sourcePriority == topPriority }

        // Sweep elementary intervals; resolve overlaps by stage precedence.
        let bounds = Array(Set(chosen.flatMap { [$0.start, $0.end] })).sorted()
        var pieces: [(start: Date, end: Date, stage: SleepStage)] = []
        for i in 0..<max(bounds.count - 1, 0) {
            let a = bounds[i], b = bounds[i + 1]
            let covering = chosen.filter { $0.start <= a && $0.end >= b }
            guard let top = covering.max(by: { $0.stage.precedence < $1.stage.precedence }) else { continue }
            if let last = pieces.last, last.stage == top.stage, last.end == a {
                pieces[pieces.count - 1].end = b
            } else {
                pieces.append((a, b, top.stage))
            }
        }

        var night = SleepNight(asleep: 0, awake: 0, core: 0, deep: 0, rem: 0, unspecified: 0,
                               mainOnset: window.start, mainWake: window.start, mainAsleep: 0)
        night.stages = pieces.map { StageSpan(start: $0.start, end: $0.end, stage: $0.stage) }
        for p in pieces {
            let d = p.end.timeIntervalSince(p.start)
            switch p.stage {
            case .core: night.core += d
            case .deep: night.deep += d
            case .rem: night.rem += d
            case .asleepUnspecified: night.unspecified += d
            case .awake: night.awake += d
            case .inBed: break
            }
            if p.stage.isAsleep { night.asleep += d }
        }
        guard night.asleep > 0 else { return nil }

        // Cluster asleep pieces into bouts.
        var bouts: [(onset: Date, wake: Date, asleep: TimeInterval)] = []
        for p in pieces where p.stage.isAsleep {
            let d = p.end.timeIntervalSince(p.start)
            if let last = bouts.last, p.start.timeIntervalSince(last.wake) < boutMergeGap {
                bouts[bouts.count - 1].wake = p.end
                bouts[bouts.count - 1].asleep += d
            } else {
                bouts.append((p.start, p.end, d))
            }
        }
        // Ties go to the later bout (the one closest to waking).
        let main = bouts.enumerated().max { l, r in
            l.element.asleep != r.element.asleep ? l.element.asleep < r.element.asleep : l.offset < r.offset
        }!.element
        night.mainOnset = main.onset
        night.mainWake = main.wake
        night.mainAsleep = main.asleep
        // Awake time outside the main bout is not counted against the night.
        return night
    }
}

public struct SleepNeed: Codable, Sendable, Equatable {
    public var base: TimeInterval
    public var debtRepayment: TimeInterval
    public var strainAdjustment: TimeInterval
    public var debt: TimeInterval
    public var total: TimeInterval { base + debtRepayment + strainAdjustment }
}

public enum SleepModel {
    /// - Parameters:
    ///   - priorNightsAsleep: sleep for the nights before the target night (nil = no data).
    ///   - priorDayLoad: training load of the day before the target night.
    ///   - ctl: chronic load going into that day.
    public static func need(baseHours: Double,
                            priorNightsAsleep: [TimeInterval?],
                            priorDayLoad: Double?,
                            ctl: Double?,
                            params: ModelParameters) -> SleepNeed {
        let base = baseHours * 3600
        let debt = priorNightsAsleep.compactMap { $0 }.reduce(0) { $0 + max(0, base - $1) }
        let repay = min(debt * params.sleepDebtRepayFraction, params.sleepDebtRepayCap)
        var strain: TimeInterval = 0
        if let load = priorDayLoad, let c = ctl, c >= params.minCTLForTargets {
            strain = Stats.clamp((load / c - 1) * params.sleepStrainAdjustPerUnitRatio,
                                 0, params.sleepStrainAdjustCap)
        }
        return SleepNeed(base: base, debtRepayment: repay, strainAdjustment: strain, debt: debt)
    }

    /// Standard deviation of main-bout midpoints, in minutes. Inputs are minutes
    /// since each night's 18:00 window start, so midnight never wraps around.
    public static func midpointVariability(minutesSinceWindowStart: [Double],
                                           params: ModelParameters) -> Double? {
        guard minutesSinceWindowStart.count >= params.consistencyMinNights else { return nil }
        return Stats.standardDeviation(minutesSinceWindowStart)
    }

    /// 0...100 composite; components renormalised over what is available.
    public static func score(performance: Double,
                             efficiency: Double?,
                             midpointSDMinutes: Double?) -> Int {
        var total = 0.7 * min(max(performance, 0), 1)
        var weight = 0.7
        if let e = efficiency {
            total += 0.15 * Stats.clamp((e - 0.70) / 0.25, 0, 1)
            weight += 0.15
        }
        if let sd = midpointSDMinutes {
            total += 0.15 * Stats.clamp(1 - (sd - 15) / 75, 0, 1)
            weight += 0.15
        }
        return Int((100 * total / weight).rounded())
    }
}
