import Foundation

public struct LoadPoint: Codable, Sendable, Equatable {
    public let day: Day
    public let load: Double
    public let observed: Bool
    /// Acute (fatigue) and chronic (fitness) EWMAs after including `load`.
    public let atl: Double
    public let ctl: Double
}

public enum LoadModel {
    public static func decay(days: Double) -> Double {
        1 - exp(-1 / days)
    }

    /// Unobserved days (watch not worn) are counted as zero load and reported
    /// via `observed` so callers can down-weight confidence.
    public static func run(days: [Day], loads: [Double?], params: ModelParameters) -> [LoadPoint] {
        precondition(days.count == loads.count)
        let ka = decay(days: params.atlDays)
        let kc = decay(days: params.ctlDays)
        let seedValues = loads.prefix(params.loadSeedDays).compactMap { $0 }
        let seed = Stats.mean(seedValues) ?? 0
        var atl = seed, ctl = seed
        var out: [LoadPoint] = []
        out.reserveCapacity(days.count)
        for (d, l) in zip(days, loads) {
            let x = l ?? 0
            atl += (x - atl) * ka
            ctl += (x - ctl) * kc
            out.append(LoadPoint(day: d, load: x, observed: l != nil, atl: atl, ctl: ctl))
        }
        return out
    }

    /// Largest load today that keeps ATL/CTL <= `ratio` after today's update.
    /// Solves ATL(1-ka) + L*ka <= r * (CTL(1-kc) + L*kc) for L.
    public static func ceiling(atl: Double, ctl: Double, ratio: Double, params: ModelParameters) -> Double? {
        let ka = decay(days: params.atlDays)
        let kc = decay(days: params.ctlDays)
        let denom = ka - ratio * kc
        guard denom > 0, ratio > 0 else { return nil }
        return max(0, (ratio * ctl * (1 - kc) - atl * (1 - ka)) / denom)
    }
}
