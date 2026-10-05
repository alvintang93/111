import Foundation

// MARK: - Inputs (read from Health by the app, cached on the watch)

public enum BiomarkerKind: String, Codable, Sendable, CaseIterable {
    /// mL/kg/min
    case vo2Max
    /// mmHg
    case systolic, diastolic
    /// Percent (0-100)
    case bodyFat
    /// kg
    case leanMass, bodyMass
    /// mg/dL
    case glucose
    /// Oxygen saturation, percent (HealthKit stores a 0-1 fraction; the app converts).
    case spo2

    /// Accepted range in display units. Values outside are rejected and counted, never clamped.
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .vo2Max: return 10...90
        case .systolic: return 60...260
        case .diastolic: return 30...160
        case .bodyFat: return 2...70
        case .leanMass: return 15...200
        case .bodyMass: return 20...350
        case .glucose: return 20...600
        case .spo2: return 50...100
        }
    }
}

/// HealthKit percent quantities are fractions (0.97 = 97 %).
public enum HealthUnits {
    /// Converts a HealthKit percent fraction to percent. Nil when the input is
    /// not a valid fraction (such values are rejected, not rescaled).
    public static func percent(fromFraction f: Double) -> Double? {
        guard f.isFinite, (0...1).contains(f) else { return nil }
        return f * 100
    }
}

public struct NutritionDay: Codable, Sendable, Equatable, Identifiable {
    public var day: Day
    public var energyKcal: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    public var id: String { day.description }

    public init(day: Day, energyKcal: Double? = nil, proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil) {
        self.day = day
        self.energyKcal = energyKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    var isEmpty: Bool { energyKcal == nil && proteinG == nil && carbsG == nil && fatG == nil }
}

/// A day with menstrual flow recorded in Health (any level except "none").
public struct FlowDay: Codable, Sendable, Equatable {
    public var day: Day
    /// 1 unspecified, 2 light, 3 medium, 4 heavy.
    public var level: Int

    public init(day: Day, level: Int) {
        self.day = day
        self.level = level
    }
}

/// One run's form metrics, averaged over the workout by Health.
public struct RunMetrics: Codable, Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    public var distanceKm: Double?
    public var steps: Double?
    public var strideLengthM: Double?
    public var verticalOscillationCm: Double?
    public var groundContactMs: Double?
    public var powerW: Double?
    public var speedMS: Double?

    public init(start: Date, end: Date, distanceKm: Double? = nil, steps: Double? = nil, strideLengthM: Double? = nil,
                verticalOscillationCm: Double? = nil, groundContactMs: Double? = nil, powerW: Double? = nil,
                speedMS: Double? = nil) {
        self.start = start
        self.end = end
        self.distanceKm = distanceKm
        self.steps = steps
        self.strideLengthM = strideLengthM
        self.verticalOscillationCm = verticalOscillationCm
        self.groundContactMs = groundContactMs
        self.powerW = powerW
        self.speedMS = speedMS
    }

    public var id: Date { start }
    public var minutes: Double { end.timeIntervalSince(start) / 60 }
    /// Steps per minute over the whole run.
    public var cadence: Double? { steps.flatMap { minutes > 0 ? $0 / minutes : nil } }
    /// Minutes per km.
    public var pace: Double? {
        if let d = distanceKm, d > 0.2 { return minutes / d }
        if let v = speedMS, v > 0 { return 1000 / (v * 60) }
        return nil
    }
}

public struct BiomarkerInput: Codable, Sendable, Equatable {
    /// Keyed by `BiomarkerKind.rawValue`.
    public var series: [String: [TimedValue]]
    public var nutrition: [NutritionDay]
    public var flow: [FlowDay]
    public var runs: [RunMetrics]
    public var fetchedAt: Date?
    /// Inputs whose last read failed (previous values kept). Distinguishes a
    /// failed query from "no data".
    public var failed: [String]?

    public init(series: [String: [TimedValue]] = [:], nutrition: [NutritionDay] = [], flow: [FlowDay] = [],
                runs: [RunMetrics] = [], fetchedAt: Date? = nil, failed: [String]? = nil) {
        self.series = series
        self.nutrition = nutrition
        self.flow = flow
        self.runs = runs
        self.fetchedAt = fetchedAt
        self.failed = failed
    }

    /// Raw samples as cached. Use `clean(_:asOf:)` for anything shown to the user.
    public subscript(_ kind: BiomarkerKind) -> [TimedValue] {
        get { series[kind.rawValue] ?? [] }
        set { series[kind.rawValue] = newValue }
    }

    /// Range-checked, de-duplicated, future-filtered samples, oldest first, with what was rejected.
    public func clean(_ kind: BiomarkerKind, asOf: Date, limits: PlausibilityLimits = PlausibilityLimits()) -> (samples: [TimedValue], stats: InputStats) {
        var stats = InputStats()
        let out = Sanitizer.timed(self[kind], range: kind.plausibleRange, within: DateInterval(start: .distantPast, end: .distantFuture),
                                  asOf: asOf, limits: limits, stats: &stats)
        return (out, stats)
    }

    public func didFail(_ kind: BiomarkerKind) -> Bool { failed?.contains(kind.rawValue) == true }
}

// MARK: - Trends and projections

public struct Trend: Codable, Sendable, Equatable {
    public var latest: Double
    public var latestDate: Date
    public var count: Int
    public var spanDays: Double
    /// Theil-Sen slope; nil with fewer than 4 readings or under 14 days of span.
    public var slopePerWeek: Double?
    public var projected30: Double?
    public var projectedLow: Double?
    public var projectedHigh: Double?
    /// Readings in the window (at most 60, evenly thinned), oldest first.
    public var points: [TimedValue]
}

public enum TrendModel {
    /// Robust trend over the last `windowDays`: the Theil-Sen slope (median of
    /// pairwise slopes) and a median intercept, so single odd readings cannot
    /// swing it. The projection band is ±1.96 robust residual SDs, widened by
    /// √(1 + horizon/span) because extrapolating past the observed span is less certain.
    public static func fit(_ samples: [TimedValue], asOf: Date, windowDays: Double = 90, horizonDays: Double = 30,
                           minCount: Int = 4, minSpanDays: Double = 14) -> Trend? {
        let from = asOf.addingTimeInterval(-windowDays * 86400)
        let xs = samples.filter { $0.start >= from && $0.start <= asOf && $0.value.isFinite }
            .sorted { $0.start < $1.start }
        guard let last = xs.last, let first = xs.first else { return nil }
        let span = last.start.timeIntervalSince(first.start) / 86400
        var trend = Trend(latest: last.value, latestDate: last.start, count: xs.count, spanDays: span,
                          slopePerWeek: nil, projected30: nil, projectedLow: nil, projectedHigh: nil,
                          points: thin(xs, to: 60))
        guard xs.count >= minCount, span >= minSpanDays else { return trend }
        let recent = Array(xs.suffix(150))
        let t = recent.map { $0.start.timeIntervalSince(first.start) / 86400 }
        let y = recent.map(\.value)
        var slopes: [Double] = []
        slopes.reserveCapacity(recent.count * recent.count / 2)
        for i in 0..<recent.count {
            for j in (i + 1)..<recent.count where t[j] - t[i] > 1e-6 {
                slopes.append((y[j] - y[i]) / (t[j] - t[i]))
            }
        }
        guard let slope = Stats.median(slopes),
              let intercept = Stats.median(zip(t, y).map { $0.1 - slope * $0.0 }) else { return trend }
        let residuals = zip(t, y).map { $0.1 - (intercept + slope * $0.0) }
        let scale = 1.4826 * (Stats.mad(residuals) ?? 0)
        let tEnd = asOf.timeIntervalSince(first.start) / 86400 + horizonDays
        let projected = intercept + slope * tEnd
        let half = 1.96 * scale * (1 + horizonDays / max(span, 1)).squareRoot()
        trend.slopePerWeek = slope * 7
        trend.projected30 = projected
        trend.projectedLow = projected - half
        trend.projectedHigh = projected + half
        return trend
    }

    static func thin(_ xs: [TimedValue], to n: Int) -> [TimedValue] {
        guard xs.count > n, n > 1 else { return xs }
        let step = Double(xs.count - 1) / Double(n - 1)
        return (0..<n).map { xs[Int((Double($0) * step).rounded())] }
    }
}

// MARK: - Biological age

public struct AgeComponent: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// Years added (positive) or subtracted (negative).
    public var years: Double
    public var detail: String
    public var id: String { name }
}

public struct BiologicalAgeEstimate: Codable, Sendable, Equatable {
    public var estimate: Double
    public var chronological: Int
    /// Starting point (fitness age from VO2 max, else chronological age) plus adjustments.
    public var components: [AgeComponent]
}

public enum BiologicalAgeModel {
    /// Typical VO2 max by age (mL/kg/min), a linear fit to published age norms
    /// for adults 20-70. Unspecified sex uses the midpoint.
    public static func typicalVO2Max(age: Double, sex: Sex) -> Double {
        let (base, rate) = coefficients(sex)
        return base - rate * (age - 20)
    }

    static func coefficients(_ sex: Sex) -> (Double, Double) {
        switch sex {
        case .male: return (52.0, 0.40)
        case .female: return (44.0, 0.35)
        case .unspecified: return (48.0, 0.375)
        }
    }

    /// The age at which your VO2 max would be typical ("fitness age").
    public static func fitnessAge(vo2Max: Double, sex: Sex) -> Double {
        let (base, rate) = coefficients(sex)
        return Stats.clamp(20 + (base - vo2Max) / rate, 18, 90)
    }

    /// Resting HR: +1.7 years per 10 bpm above 60 (a hazard ratio of about 1.16
    /// per 10 bpm, converted at about 1.09 per year of age). Halved when VO2 max
    /// is also used, since the two overlap.
    public static func restingHRYears(_ rhr: Double, withVO2: Bool) -> Double {
        let years = Stats.clamp((rhr - 60) / 10 * 1.7, -3, 6)
        return withVO2 ? years / 2 : years
    }

    /// Average sleep under 7 h or over 9 h adds years (U-shaped association), capped at 3.
    public static func sleepYears(hours: Double) -> Double {
        if hours < 7 { return min(1.3 * (7 - hours), 3) }
        if hours > 9 { return min(1.0 * (hours - 9), 3) }
        return 0
    }

    public static func estimate(age: Int, sex: Sex, vo2Max: Double?, restingHR: Double?,
                                averageSleepHours: Double?) -> BiologicalAgeEstimate {
        var components: [AgeComponent] = []
        let start: Double
        if let v = vo2Max {
            start = fitnessAge(vo2Max: v, sex: sex)
            components.append(AgeComponent(name: "Cardio fitness", years: start - Double(age),
                                           detail: String(format: "VO2 max %.1f vs typical %.1f at your age", v,
                                                          typicalVO2Max(age: Double(age), sex: sex))))
        } else {
            start = Double(age)
        }
        var total = start
        if let r = restingHR {
            let y = restingHRYears(r, withVO2: vo2Max != nil)
            total += y
            components.append(AgeComponent(name: "Resting HR", years: y, detail: String(format: "%.0f bpm (reference 60)", r)))
        }
        if let h = averageSleepHours {
            let y = sleepYears(hours: h)
            total += y
            components.append(AgeComponent(name: "Sleep", years: y, detail: String(format: "%.1f h average (7-9 h adds nothing)", h)))
        }
        let clamped = Stats.clamp(total, max(18, Double(age) - 20), Double(age) + 20)
        return BiologicalAgeEstimate(estimate: clamped, chronological: age, components: components)
    }
}

// MARK: - Blood pressure, glucose, nutrition

/// American Heart Association reading categories, applied to one reading.
public enum BloodPressureCategory: String, Codable, Sendable {
    case normal, elevated, high1, high2

    public init(systolic: Double, diastolic: Double) {
        if systolic >= 140 || diastolic >= 90 { self = .high2 } else if systolic >= 130 || diastolic >= 80 { self = .high1 } else if systolic >= 120 { self = .elevated } else { self = .normal }
    }
}

public struct BloodPressureSummary: Codable, Sendable, Equatable {
    public var latestSystolic: Double
    public var latestDiastolic: Double
    public var latestDate: Date
    public var category: BloodPressureCategory
    public var readings30d: Int
    public var averageSystolic30d: Double?
    public var averageDiastolic30d: Double?
    public var systolic: Trend?
    public var diastolic: Trend?

    /// Pairs systolic and diastolic samples recorded at the same time.
    public static func make(systolic: [TimedValue], diastolic: [TimedValue], asOf: Date) -> BloodPressureSummary? {
        let dia = Dictionary(diastolic.map { ($0.start, $0.value) }, uniquingKeysWith: { a, _ in a })
        let pairs = systolic.compactMap { s in dia[s.start].map { (s.start, s.value, $0) } }
            .filter { $0.0 <= asOf }.sorted { $0.0 < $1.0 }
        guard let last = pairs.last else { return nil }
        let recent = pairs.filter { $0.0 >= asOf.addingTimeInterval(-30 * 86400) }
        return BloodPressureSummary(
            latestSystolic: last.1, latestDiastolic: last.2, latestDate: last.0,
            category: BloodPressureCategory(systolic: last.1, diastolic: last.2),
            readings30d: recent.count,
            averageSystolic30d: Stats.mean(recent.map(\.1)), averageDiastolic30d: Stats.mean(recent.map(\.2)),
            systolic: TrendModel.fit(systolic, asOf: asOf), diastolic: TrendModel.fit(diastolic, asOf: asOf))
    }
}

public struct GlucoseSummary: Codable, Sendable, Equatable {
    public var latest: Double
    public var latestDate: Date
    public var readings24h: Int
    public var mean24h: Double?
    /// Share of the last 24 h's readings within 70-140 mg/dL.
    public var inRange24h: Double?
    /// Daily means, last 14 days, oldest first.
    public var dailyMeans: [DayValue]

    public static func make(_ samples: [TimedValue], asOf: Date, calendar: Calendar) -> GlucoseSummary? {
        let xs = samples.filter { $0.start <= asOf }.sorted { $0.start < $1.start }
        guard let last = xs.last else { return nil }
        let day = xs.filter { $0.start >= asOf.addingTimeInterval(-86400) }.map(\.value)
        var byDay: [Day: [Double]] = [:]
        for s in xs where s.start >= asOf.addingTimeInterval(-14 * 86400) { byDay[Day(s.start, calendar: calendar), default: []].append(s.value) }
        return GlucoseSummary(latest: last.value, latestDate: last.start, readings24h: day.count, mean24h: Stats.mean(day),
                              inRange24h: day.isEmpty ? nil : Double(day.filter { (70...140).contains($0) }.count) / Double(day.count),
                              dailyMeans: byDay.keys.sorted().map { DayValue(day: $0, value: Stats.mean(byDay[$0]!)!) })
    }
}

public struct DayValue: Codable, Sendable, Equatable, Identifiable {
    public var day: Day
    public var value: Double
    public var id: String { day.description }

    public init(day: Day, value: Double) {
        self.day = day
        self.value = value
    }
}

public struct NutritionSummary: Codable, Sendable, Equatable {
    public var today: NutritionDay?
    /// Mean over logged days in the last 7 (days with nothing logged are skipped).
    public var average7: NutritionDay?
    public var loggedDays7: Int
    public var proteinPerKg7: Double?
    public var days: [NutritionDay]

    public static func make(_ days: [NutritionDay], today: Day, bodyMassKg: Double?, calendar: Calendar) -> NutritionSummary? {
        let logged = days.filter { !$0.isEmpty && $0.day <= today }.sorted { $0.day < $1.day }
        guard !logged.isEmpty else { return nil }
        let from = today.adding(-6, calendar: calendar)
        let week = logged.filter { $0.day >= from }
        func avg(_ k: KeyPath<NutritionDay, Double?>) -> Double? { Stats.mean(week.compactMap { $0[keyPath: k] }) }
        let average = week.isEmpty ? nil : NutritionDay(day: today, energyKcal: avg(\.energyKcal), proteinG: avg(\.proteinG),
                                                         carbsG: avg(\.carbsG), fatG: avg(\.fatG))
        return NutritionSummary(today: logged.last { $0.day == today }, average7: average, loggedDays7: week.count,
                                proteinPerKg7: average?.proteinG.flatMap { p in bodyMassKg.map { p / $0 } },
                                days: Array(logged.suffix(14)))
    }
}

// MARK: - Cycle

public enum CyclePhase: String, Codable, Sendable, CaseIterable {
    case menstrual, follicular, ovulatory, luteal
}

public struct PhaseStats: Codable, Sendable, Equatable, Identifiable {
    public var phase: CyclePhase
    public var nights: Int
    /// Mean next-morning HRV vs your 60-day baseline, percent.
    public var hrvDeltaPercent: Double?
    /// Mean wrist temperature vs your median over the same days, °C.
    public var temperatureDelta: Double?
    public var id: String { phase.rawValue }
}

public struct CycleSummary: Codable, Sendable, Equatable {
    public var lastStart: Day
    public var cycleDay: Int
    public var medianLength: Int?
    public var cyclesUsed: Int
    public var predictedNextStart: Day
    public var phase: CyclePhase
    public var byPhase: [PhaseStats]
}

public enum CycleModel {
    /// A flow day starts a new period when the previous flow day is at least 10 days earlier.
    public static func starts(_ flow: [FlowDay], calendar: Calendar) -> [Day] {
        let days = Array(Set(flow.map(\.day))).sorted()
        var out: [Day] = []
        var previous: Day?
        for d in days {
            if let p = previous, p.adding(10, calendar: calendar) > d {
                previous = d
                continue
            }
            out.append(d)
            previous = d
        }
        return out
    }

    static func daysBetween(_ a: Day, _ b: Day, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: a.date(hour: 12, calendar: calendar), to: b.date(hour: 12, calendar: calendar)).day ?? 0
    }

    /// Phase on a cycle day for a cycle of `length` days. Ovulation is placed 14 days before the next period.
    public static func phase(cycleDay: Int, length: Int, periodDays: Int) -> CyclePhase {
        let ovulation = max(length - 14, periodDays + 1)
        if cycleDay <= periodDays { return .menstrual }
        if abs(cycleDay - ovulation) <= 1 { return .ovulatory }
        return cycleDay < ovulation ? .follicular : .luteal
    }

    public static func summarize(flow: [FlowDay], today: Day, calendar: Calendar,
                                 hrvDeviation: [Day: Double], temperature: [Day: Double]) -> CycleSummary? {
        let s = starts(flow.filter { $0.day <= today }, calendar: calendar)
        guard let last = s.last else { return nil }
        let lengths = zip(s, s.dropFirst()).map { daysBetween($0, $1, calendar: calendar) }.filter { (18...45).contains($0) }
        let recent = Array(lengths.suffix(6))
        let median = Stats.median(recent.map(Double.init)).map { Int($0.rounded()) }
        let length = median ?? 28
        let flowDays = Set(flow.map(\.day))
        func periodDays(from start: Day) -> Int {
            var n = 0
            while flowDays.contains(start.adding(n, calendar: calendar)) && n < 10 { n += 1 }
            return max(n, 1)
        }
        let cycleDay = daysBetween(last, today, calendar: calendar) + 1
        let phaseToday = phase(cycleDay: cycleDay, length: length, periodDays: periodDays(from: last))

        // Nightly HRV and temperature by phase over the recorded cycles.
        var hrv: [CyclePhase: [Double]] = [:], temp: [CyclePhase: [Double]] = [:]
        let tempMedian = Stats.median(Array(temperature.values)) ?? 0
        for (k, start) in s.enumerated() {
            let end = k + 1 < s.count ? s[k + 1] : today.adding(1, calendar: calendar)
            let len = k + 1 < s.count ? daysBetween(start, end, calendar: calendar) : length
            guard (18...45).contains(len) || k + 1 == s.count else { continue }
            let pd = periodDays(from: start)
            for d in Day.range(from: start, to: end.adding(-1, calendar: calendar), calendar: calendar) {
                let p = phase(cycleDay: daysBetween(start, d, calendar: calendar) + 1, length: len, periodDays: pd)
                if let h = hrvDeviation[d] { hrv[p, default: []].append(h) }
                if let t = temperature[d] { temp[p, default: []].append(t - tempMedian) }
            }
        }
        let stats = CyclePhase.allCases.map { p in
            PhaseStats(phase: p, nights: max(hrv[p]?.count ?? 0, temp[p]?.count ?? 0),
                       hrvDeltaPercent: Stats.mean(hrv[p] ?? []).map { (exp($0) - 1) * 100 },
                       temperatureDelta: Stats.mean(temp[p] ?? []))
        }
        return CycleSummary(lastStart: last, cycleDay: cycleDay, medianLength: median, cyclesUsed: recent.count,
                            predictedNextStart: last.adding(length, calendar: calendar), phase: phaseToday, byPhase: stats)
    }
}

// MARK: - Running form

/// Median form metrics over a set of runs.
public struct RunTypical: Codable, Sendable, Equatable {
    public var cadence: Double?
    public var strideLengthM: Double?
    public var verticalOscillationCm: Double?
    public var groundContactMs: Double?
    public var powerW: Double?
    public var pace: Double?
}

public struct RunningSummary: Codable, Sendable, Equatable {
    public var latest: RunMetrics
    /// Medians over the other runs in the window (needs at least 2).
    public var typical: RunTypical?
    public var runs: Int
    public var recent: [RunMetrics]

    public static func make(_ runs: [RunMetrics], asOf: Date, windowDays: Double = 60) -> RunningSummary? {
        let xs = runs.filter { $0.start <= asOf && $0.start >= asOf.addingTimeInterval(-windowDays * 86400) }
            .sorted { $0.start < $1.start }
        guard let last = xs.last else { return nil }
        let others = Array(xs.dropLast())
        var typical: RunTypical?
        if others.count >= 2 {
            func m(_ f: (RunMetrics) -> Double?) -> Double? { Stats.median(others.compactMap(f)) }
            typical = RunTypical(cadence: m(\.cadence), strideLengthM: m(\.strideLengthM),
                                 verticalOscillationCm: m(\.verticalOscillationCm), groundContactMs: m(\.groundContactMs),
                                 powerW: m(\.powerW), pace: m(\.pace))
        }
        return RunningSummary(latest: last, typical: typical, runs: xs.count, recent: Array(xs.suffix(10)))
    }
}
