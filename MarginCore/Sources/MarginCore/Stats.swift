import Foundation

public enum Stats {
    public static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Linear-interpolation quantile (R type 7 / NumPy default).
    public static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty, q >= 0, q <= 1 else { return nil }
        let s = xs.sorted()
        let h = Double(s.count - 1) * q
        let lo = Int(h.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        return s[lo] + (h - Double(lo)) * (s[hi] - s[lo])
    }

    public static func median(_ xs: [Double]) -> Double? {
        quantile(xs, 0.5)
    }

    /// Unbiased sample variance (n - 1). Requires n >= 2.
    public static func variance(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
    }

    public static func standardDeviation(_ xs: [Double]) -> Double? {
        variance(xs).map { $0.squareRoot() }
    }

    /// Median absolute deviation (unscaled).
    public static func mad(_ xs: [Double]) -> Double? {
        guard let m = median(xs) else { return nil }
        return median(xs.map { abs($0 - m) })
    }

    public static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }

    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }

    /// Two-sided p-value of Student's t with `df` degrees of freedom.
    public static func studentTTwoSidedP(t: Double, df: Double) -> Double? {
        guard df > 0, t.isFinite else { return nil }
        let x = df / (df + t * t)
        return regularizedIncompleteBeta(x, a: df / 2, b: 0.5)
    }

    /// I_x(a, b) via the continued-fraction expansion (Lentz's method).
    public static func regularizedIncompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lnFront = lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x)
        let front = exp(lnFront)
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(x, a: a, b: b) / a
        }
        return 1 - front * betaContinuedFraction(1 - x, a: b, b: a) / b
    }

    private static func betaContinuedFraction(_ x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300
        let eps = 1e-15
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1...500 {
            let md = Double(m), m2 = 2 * md
            var aa = md * (b - md) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + md) * (qab + md) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < eps { break }
        }
        return h
    }
}

/// Personal baseline using median and MAD so a few outlier nights cannot move it.
public struct RobustBaseline: Codable, Sendable, Equatable {
    public let center: Double
    /// 1.4826 * MAD (consistent with SD under normality), floored to avoid
    /// near-zero denominators when history is unusually flat.
    public let scale: Double
    public let count: Int

    public init?(values: [Double], minCount: Int, scaleFloor: Double) {
        guard values.count >= max(minCount, 1),
              let c = Stats.median(values),
              let m = Stats.mad(values) else { return nil }
        center = c
        scale = max(1.4826 * m, scaleFloor)
        count = values.count
    }

    public func z(_ x: Double) -> Double {
        (x - center) / scale
    }
}
