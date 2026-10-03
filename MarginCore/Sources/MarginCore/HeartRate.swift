import Foundation

public struct HRSample: Sendable, Equatable {
    public let date: Date
    public let bpm: Double

    public init(date: Date, bpm: Double) {
        self.date = date
        self.bpm = bpm
    }
}

/// Seconds spent at each whole bpm over a window. Storing time-at-HR instead of
/// a load number lets every historic day be re-scored exactly when HRmax,
/// HRrest or sex change. Quantisation error is at most 0.5 bpm.
public struct HeartRateHistogram: Codable, Sendable, Equatable {
    public static let maxBPM = 250
    public private(set) var seconds: [Double]

    public init() {
        seconds = Array(repeating: 0, count: Self.maxBPM + 1)
    }

    init(secondsByBPM: [Int: Double]) {
        self.init()
        for (bpm, s) in secondsByBPM { seconds[min(max(bpm, 0), Self.maxBPM)] += s }
    }

    public var totalSeconds: Double { seconds.reduce(0, +) }

    /// Each sample holds until the next one, capped at `maxGap`, so overlapping
    /// sources and duplicated timestamps cannot inflate time.
    public static func build(samples: [HRSample], window: DateInterval, maxGap: TimeInterval) -> HeartRateHistogram {
        var h = HeartRateHistogram()
        let inWindow = samples
            .filter { $0.date >= window.start && $0.date < window.end && $0.bpm.isFinite && $0.bpm > 0 }
            .sorted { $0.date < $1.date }
        for (i, s) in inWindow.enumerated() {
            let next = i + 1 < inWindow.count ? inWindow[i + 1].date : window.end
            let dt = min(max(next.timeIntervalSince(s.date), 0), maxGap)
            guard dt > 0 else { continue }
            let bin = min(max(Int(s.bpm.rounded()), 0), maxBPM)
            h.seconds[bin] += dt
        }
        return h
    }

    /// Banister TRIMP: sum of minutes * HRr * a * exp(b * HRr), HRr = heart-rate reserve fraction.
    public func trimp(hrRest: Double, hrMax: Double, sex: Sex, floorHRR: Double) -> Double? {
        guard hrMax - hrRest >= 20 else { return nil }
        let (a, b) = Self.banisterCoefficients(sex)
        var total = 0.0
        for (bpm, s) in seconds.enumerated() where s > 0 {
            let hrr = (Double(bpm) - hrRest) / (hrMax - hrRest)
            guard hrr >= floorHRR else { continue }
            let x = min(hrr, 1)
            total += (s / 60) * x * a * exp(b * x)
        }
        return total
    }

    /// Male coefficients are used when sex is unspecified.
    public static func banisterCoefficients(_ sex: Sex) -> (Double, Double) {
        sex == .female ? (0.86, 1.67) : (0.64, 1.92)
    }

    /// Seconds in heart-rate-reserve zones: <50%, 50-60, 60-70, 70-80, 80-90, >=90.
    public func zoneSeconds(hrRest: Double, hrMax: Double) -> [Double] {
        var zones = Array(repeating: 0.0, count: 6)
        guard hrMax > hrRest else { return zones }
        for (bpm, s) in seconds.enumerated() where s > 0 {
            let hrr = (Double(bpm) - hrRest) / (hrMax - hrRest)
            let idx: Int
            switch hrr {
            case ..<0.5: idx = 0
            case ..<0.6: idx = 1
            case ..<0.7: idx = 2
            case ..<0.8: idx = 3
            case ..<0.9: idx = 4
            default: idx = 5
            }
            zones[idx] += s
        }
        return zones
    }
}
