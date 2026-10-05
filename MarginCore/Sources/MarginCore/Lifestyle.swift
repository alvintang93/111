import Foundation

// MARK: - Caffeine and hydration

public enum IntakeKind: String, Codable, Sendable, CaseIterable {
    /// Amount in mg.
    case caffeine
    /// Amount in ml.
    case water
}

public struct IntakeEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var kind: IntakeKind
    public var amount: Double
    /// e.g. "Espresso". Empty for a plain amount.
    public var label: String

    public init(id: UUID = UUID(), date: Date, kind: IntakeKind, amount: Double, label: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.amount = amount
        self.label = label
    }
}

/// User-editable lifestyle settings. Decoding tolerates missing keys so new
/// settings never reset existing ones.
public struct LifestyleSettings: Codable, Sendable, Equatable {
    public var caffeineHalfLifeHours = 5.0
    /// Caffeine still in the body at bedtime above this is flagged, and the cut-off is solved for it.
    public var bedtimeCaffeineLimitMg = 50.0
    /// Dose assumed when solving the cut-off ("one more coffee").
    public var typicalDoseMg = 95.0
    public var waterMlPerKg = 35.0
    /// Overrides Health's body mass for the fluid target.
    public var bodyMassKg: Double?
    /// Used until 3 nights of sleep give a usual bedtime. Minutes after midnight.
    public var defaultBedtimeMinutes = 23 * 60
    /// Tiles on the Today page, in order.
    public var pinnedMetrics: [DashboardMetric] = [.strain, .energy, .stress, .sleep]
    public var checkIns = CheckInSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LifestyleSettings()
        caffeineHalfLifeHours = try c.decodeIfPresent(Double.self, forKey: .caffeineHalfLifeHours) ?? d.caffeineHalfLifeHours
        bedtimeCaffeineLimitMg = try c.decodeIfPresent(Double.self, forKey: .bedtimeCaffeineLimitMg) ?? d.bedtimeCaffeineLimitMg
        typicalDoseMg = try c.decodeIfPresent(Double.self, forKey: .typicalDoseMg) ?? d.typicalDoseMg
        waterMlPerKg = try c.decodeIfPresent(Double.self, forKey: .waterMlPerKg) ?? d.waterMlPerKg
        bodyMassKg = try c.decodeIfPresent(Double.self, forKey: .bodyMassKg)
        defaultBedtimeMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultBedtimeMinutes) ?? d.defaultBedtimeMinutes
        // Unknown metric names (from a newer version) are dropped, not fatal.
        let raw = try c.decodeIfPresent([String].self, forKey: .pinnedMetrics)
        pinnedMetrics = raw.map { $0.compactMap(DashboardMetric.init(rawValue:)) } ?? d.pinnedMetrics
        checkIns = try c.decodeIfPresent(CheckInSettings.self, forKey: .checkIns) ?? d.checkIns
    }
}

public struct CheckInSettings: Codable, Sendable, Equatable {
    public var morningSummary = true
    public var eveningJournal = true
    /// Minutes after midnight.
    public var eveningJournalMinutes = 21 * 60
    public var caffeineCutoff = true
    public var weeklyReview = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CheckInSettings()
        morningSummary = try c.decodeIfPresent(Bool.self, forKey: .morningSummary) ?? d.morningSummary
        eveningJournal = try c.decodeIfPresent(Bool.self, forKey: .eveningJournal) ?? d.eveningJournal
        eveningJournalMinutes = try c.decodeIfPresent(Int.self, forKey: .eveningJournalMinutes) ?? d.eveningJournalMinutes
        caffeineCutoff = try c.decodeIfPresent(Bool.self, forKey: .caffeineCutoff) ?? d.caffeineCutoff
        weeklyReview = try c.decodeIfPresent(Bool.self, forKey: .weeklyReview) ?? d.weeklyReview
    }
}

public struct CaffeinePoint: Codable, Sendable, Equatable, Identifiable {
    public var date: Date
    public var mg: Double
    public var id: Date { date }
}

public struct IntakeSummary: Codable, Sendable, Equatable {
    public var caffeineTodayMg: Double
    public var caffeineNowMg: Double
    public var caffeineAtBedtimeMg: Double
    public var bedtime: Date
    /// True when the bedtime is your usual sleep onset, false for the default.
    public var bedtimeFromHistory: Bool
    /// Latest time one typical dose keeps bedtime caffeine under the limit.
    /// Nil when bedtime caffeine is already at or above the limit.
    public var cutoff: Date?
    public var limitMg: Double
    public var waterTodayMl: Double
    public var waterTargetMl: Double
    /// Caffeine in the body from 06:00 to one hour after bedtime, every 30 min.
    public var curve: [CaffeinePoint]
    public var entriesToday: [IntakeEntry]
}

public enum CaffeineModel {
    /// Absorption is spread evenly over this long after a dose.
    public static let absorption: TimeInterval = 45 * 60

    static func k(halfLifeHours: Double) -> Double { log(2) / (max(halfLifeHours, 0.5) * 3600) }

    /// mg of one dose still in the body at `t`: constant-rate absorption over
    /// `absorption` with first-order elimination throughout.
    public static func remaining(dose: Double, takenAt: Date, at t: Date, halfLifeHours: Double) -> Double {
        let tau = t.timeIntervalSince(takenAt)
        guard tau > 0, dose > 0 else { return 0 }
        let k = k(halfLifeHours: halfLifeHours), T = absorption
        if tau <= T { return dose / T * (1 - exp(-k * tau)) / k }
        return dose / T * (1 - exp(-k * T)) / k * exp(-k * (tau - T))
    }

    public static func remaining(_ entries: [IntakeEntry], at t: Date, halfLifeHours: Double) -> Double {
        entries.filter { $0.kind == .caffeine }
            .reduce(0) { $0 + remaining(dose: $1.amount, takenAt: $1.date, at: t, halfLifeHours: halfLifeHours) }
    }

    /// Latest time to take `dose` so that caffeine at `bedtime` stays at or
    /// under `limit`, given what is already in the body. Nil if the existing
    /// caffeine alone reaches the limit.
    public static func cutoff(existing: [IntakeEntry], bedtime: Date, dose: Double, limit: Double,
                              halfLifeHours: Double) -> Date? {
        let residual = remaining(existing, at: bedtime, halfLifeHours: halfLifeHours)
        guard residual < limit else { return nil }
        guard dose > 0 else { return bedtime }
        let k = k(halfLifeHours: halfLifeHours), T = absorption
        // For gaps >= T: dose * (1 - e^-kT)/(kT) * e^-k(gap - T) <= limit - residual.
        let ratio = (limit - residual) * k * T / (dose * (1 - exp(-k * T)))
        let gap = ratio >= 1 ? T : T - log(ratio) / k
        return bedtime.addingTimeInterval(-gap)
    }

    /// Fluid target: ml per kg of body mass, plus about 600 ml per workout hour.
    public static func waterTarget(bodyMassKg: Double?, mlPerKg: Double, workoutMinutes: Double) -> Double {
        let ml = mlPerKg * (bodyMassKg ?? 70) + 10 * workoutMinutes
        return (ml / 50).rounded() * 50
    }
}

// MARK: - Activity status

public enum StatusKind: String, Codable, Sendable, CaseIterable {
    case unwell, sore, travel

    /// Unwell and sore days pause the load model, so time off does not read as lost fitness.
    public var pausesLoad: Bool { self != .travel }
    /// Unwell and sore days turn Push off.
    public var blocksPush: Bool { self != .travel }
}

/// A period the person marked. Days inside it are left out of every personal
/// baseline (recovery inputs and score calibration), so they cannot drag later scores.
public struct StatusPeriod: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: StatusKind
    public var start: Day
    /// Inclusive. Nil while ongoing.
    public var end: Day?

    public init(id: UUID = UUID(), kind: StatusKind, start: Day, end: Day? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
    }

    public func covers(_ day: Day) -> Bool {
        day >= start && (end.map { day <= $0 } ?? true)
    }

    public static func kinds(on day: Day, in periods: [StatusPeriod]) -> [StatusKind] {
        StatusKind.allCases.filter { k in periods.contains { $0.kind == k && $0.covers(day) } }
    }
}

// MARK: - Timeline

public struct TimelineItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case sleep, wake, workout, caffeine, water, journal, status
    }

    public var date: Date
    public var kind: Kind
    public var title: String
    public var detail: String
    public var id: String { "\(kind.rawValue)-\(date.timeIntervalSinceReferenceDate)-\(title)" }
}

public struct DayTimeline: Codable, Sendable, Equatable, Identifiable {
    public var day: Day
    public var items: [TimelineItem]
    public var id: String { day.description }
}
