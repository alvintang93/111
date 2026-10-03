import Foundation

public struct WelchResult: Sendable, Equatable {
    public let meanDifference: Double
    public let t: Double
    public let df: Double
    public let p: Double
}

public enum Hypothesis {
    /// Welch's unequal-variance t-test, two-sided. Requires n >= 2 per group.
    public static func welch(_ a: [Double], _ b: [Double]) -> WelchResult? {
        guard a.count >= 2, b.count >= 2,
              let ma = Stats.mean(a), let mb = Stats.mean(b),
              let va = Stats.variance(a), let vb = Stats.variance(b) else { return nil }
        let sa = va / Double(a.count), sb = vb / Double(b.count)
        let se = (sa + sb).squareRoot()
        guard se > 0 else { return nil }
        let t = (ma - mb) / se
        let df = (sa + sb) * (sa + sb) / (sa * sa / Double(a.count - 1) + sb * sb / Double(b.count - 1))
        guard let p = Stats.studentTTwoSidedP(t: t, df: df) else { return nil }
        return WelchResult(meanDifference: ma - mb, t: t, df: df, p: p)
    }

    /// Holm-Bonferroni step-down. Returns rejection decisions in input order.
    public static func holm(_ pValues: [Double], alpha: Double) -> [Bool] {
        let order = pValues.indices.sorted { pValues[$0] < pValues[$1] }
        var reject = Array(repeating: false, count: pValues.count)
        let m = Double(pValues.count)
        for (rank, idx) in order.enumerated() {
            guard pValues[idx] <= alpha / (m - Double(rank)) else { break }
            reject[idx] = true
        }
        return reject
    }
}

public enum TagAnalysis {
    /// Compares next-night HRV deviation after days with a tag vs. journaled
    /// days without it. Days with no journal entry are excluded entirely, so
    /// "not logged" is never treated as "did not happen".
    public static func impacts(journal: [Day: Set<String>],
                               hrvDeviation: [Day: Double],
                               calendar: Calendar,
                               params: ModelParameters) -> [TagImpact] {
        let allTags = Set(journal.values.flatMap { $0 }).sorted()
        var candidates: [(tag: String, nWith: Int, nWithout: Int, result: WelchResult)] = []
        for tag in allTags {
            var with: [Double] = [], without: [Double] = []
            // Sorted so sums (and thus p-values) are bit-for-bit reproducible.
            for day in journal.keys.sorted() {
                guard let dev = hrvDeviation[day.adding(1, calendar: calendar)] else { continue }
                if journal[day]!.contains(tag) { with.append(dev) } else { without.append(dev) }
            }
            guard with.count >= params.minTagSamples, without.count >= params.minTagSamples,
                  let r = Hypothesis.welch(with, without) else { continue }
            candidates.append((tag, with.count, without.count, r))
        }
        let decisions = Hypothesis.holm(candidates.map(\.result.p), alpha: params.tagAlpha)
        return zip(candidates, decisions).map { c, sig in
            TagImpact(tag: c.tag, nWith: c.nWith, nWithout: c.nWithout,
                      effectPercent: (exp(c.result.meanDifference) - 1) * 100,
                      pValue: c.result.p, significant: sig)
        }
        .sorted { ($0.pValue, $0.tag) < ($1.pValue, $1.tag) }
    }
}
