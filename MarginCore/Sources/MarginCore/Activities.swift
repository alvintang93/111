import Foundation

// MARK: - Logged activities

/// An activity the person recorded in Margin (live on the watch, or entered
/// afterwards). The activity type is HealthKit's own workout taxonomy
/// (`HKWorkoutActivityType.rawValue`), so there is no second taxonomy to map.
public struct LoggedActivity: Codable, Sendable, Equatable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        /// Recorded with a live workout session on the watch (heart rate sampled densely).
        case live
        /// Entered after the fact; Margin has no heart rate of its own for it.
        case manual
    }

    public var id: UUID
    public var activityType: UInt
    public var start: Date
    public var end: Date
    /// Rate of perceived exertion, 1-10.
    public var rpe: Int?
    public var notes: String
    public var origin: Origin
    /// The Health workout this activity is (saved by Margin, or an existing one it was linked to).
    public var healthWorkoutID: UUID?
    public var routineID: UUID?

    public init(id: UUID = UUID(), activityType: UInt, start: Date, end: Date, rpe: Int? = nil, notes: String = "",
                origin: Origin, healthWorkoutID: UUID? = nil, routineID: UUID? = nil) {
        self.id = id
        self.activityType = activityType
        self.start = start
        self.end = end
        self.rpe = rpe
        self.notes = notes
        self.origin = origin
        self.healthWorkoutID = healthWorkoutID
        self.routineID = routineID
    }

    public var minutes: Double { end.timeIntervalSince(start) / 60 }
    /// Session RPE load (Foster): RPE × minutes. Shown for context; not part of TRIMP or any score.
    public var sessionLoad: Double? { rpe.map { Double($0) * minutes } }
}

public struct ActivityLog: Codable, Sendable, Equatable {
    public var activities: [LoggedActivity]

    public init(activities: [LoggedActivity] = []) {
        self.activities = activities
    }
}

/// Activity types offered when logging. Raw values are HealthKit's.
public enum ActivityCatalog {
    public static let common: [UInt] = [37, 52, 13, 46, 63, 50, 20, 24, 57, 35, 16, 73, 59, 66, 44, 77, 6, 48, 79, 62, 80]

    public static let strengthTypes: Set<UInt> = [50, 20]
}

// MARK: - Reconciliation with Health

/// One activity in Margin's history, after merging Health workouts with
/// Margin's own logs. `id` is stable across syncs: it is derived from the
/// Health workout UUID when there is one, else from Margin's own UUID.
public struct ActivityEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A Health workout with no Margin log (e.g. from the Workout app).
        case healthWorkout
        /// A Margin-logged activity (possibly merged with its Health workout).
        case logged
        /// A Margin strength session (possibly merged with its Health workout).
        case strength
    }

    public var id: String
    public var kind: Kind
    public var activityType: UInt
    public var start: Date
    public var end: Date
    public var title: String
    /// Heart-rate details from the Health workout, when one exists.
    public var health: WorkoutDetail?
    public var logged: LoggedActivity?
    public var strength: StrengthSession?
    /// How the Margin log and the Health workout were matched, if they were.
    public var match: MatchRule?
    /// Heart-rate analysis of the Health workout (set by the engine).
    public var analysis: WorkoutAnalysis?

    public enum MatchRule: String, Codable, Sendable {
        /// The Margin log stores the Health workout's UUID.
        case healthID
        /// Legacy logs without a UUID: same type family, starts within 2 min, overlap ≥ 50 %.
        case timeOverlap
    }
}

public enum ActivityReconciler {
    public static let startTolerance: TimeInterval = 120
    public static let minimumOverlap = 0.5

    static func overlapFraction(_ a: (Date, Date), _ b: (Date, Date)) -> Double {
        let ov = min(a.1, b.1).timeIntervalSince(max(a.0, b.0))
        let shorter = min(a.1.timeIntervalSince(a.0), b.1.timeIntervalSince(b.0))
        guard ov > 0, shorter > 0 else { return 0 }
        return ov / shorter
    }

    static func sameFamily(_ a: UInt, _ b: UInt) -> Bool {
        a == b || (ActivityCatalog.strengthTypes.contains(a) && ActivityCatalog.strengthTypes.contains(b))
    }

    /// Whether a Health workout already covers this interval (so logging it would duplicate it).
    public static func existingWorkout(type: UInt, start: Date, end: Date, in workouts: [WorkoutDetail]) -> WorkoutDetail? {
        workouts.filter { sameFamily($0.activityType, type) && overlapFraction(($0.start, $0.end), (start, end)) >= minimumOverlap }
            .max { overlapFraction(($0.start, $0.end), (start, end)) < overlapFraction(($1.start, $1.end), (start, end)) }
    }

    /// Merges Health workouts with Margin logs. Each Health workout is matched to
    /// at most one Margin log: by UUID first, then (legacy) by time and type.
    public static func reconcile(health: [WorkoutDetail], logged: [LoggedActivity], strength: [StrengthSession],
                                 exerciseName: (String) -> String? = { _ in nil }) -> [ActivityEntry] {
        struct MarginItem {
            var start: Date, end: Date, type: UInt, healthID: UUID?
            var logged: LoggedActivity?, strength: StrengthSession?
            var id: UUID
        }
        var margin: [MarginItem] = logged.map {
            MarginItem(start: $0.start, end: $0.end, type: $0.activityType, healthID: $0.healthWorkoutID, logged: $0, strength: nil, id: $0.id)
        }
        margin += strength.filter { !$0.sets.isEmpty || $0.end != nil }.map {
            MarginItem(start: $0.start, end: $0.end ?? $0.sets.map(\.date).max() ?? $0.start, type: 50, healthID: $0.healthWorkoutID,
                       logged: nil, strength: $0, id: $0.id)
        }
        margin.sort { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        let sortedHealth = health.sorted { ($0.start, $0.healthID?.uuidString ?? "") < ($1.start, $1.healthID?.uuidString ?? "") }

        var usedHealth = Set<Int>()
        var pairs: [Int: (Int, ActivityEntry.MatchRule)] = [:]   // margin index -> (health index, rule)
        // 1. Exact identity.
        for (mi, m) in margin.enumerated() {
            guard let id = m.healthID, let hi = sortedHealth.firstIndex(where: { $0.healthID == id }), !usedHealth.contains(hi) else { continue }
            usedHealth.insert(hi)
            pairs[mi] = (hi, .healthID)
        }
        // 2. Legacy time-overlap rule, only for Margin logs that never stored a UUID.
        for (mi, m) in margin.enumerated() where pairs[mi] == nil && m.healthID == nil {
            let candidates = sortedHealth.indices.filter { hi in
                !usedHealth.contains(hi) && sameFamily(sortedHealth[hi].activityType, m.type)
                    && abs(sortedHealth[hi].start.timeIntervalSince(m.start)) <= startTolerance
                    && overlapFraction((sortedHealth[hi].start, sortedHealth[hi].end), (m.start, m.end)) >= minimumOverlap
            }
            if let best = candidates.max(by: {
                overlapFraction((sortedHealth[$0].start, sortedHealth[$0].end), (m.start, m.end))
                    < overlapFraction((sortedHealth[$1].start, sortedHealth[$1].end), (m.start, m.end))
            }) {
                usedHealth.insert(best)
                pairs[mi] = (best, .timeOverlap)
            }
        }

        func healthKey(_ w: WorkoutDetail) -> String {
            w.healthID.map { "hk-\($0.uuidString)" } ?? "hk-\(Int(w.start.timeIntervalSinceReferenceDate))-\(w.activityType)"
        }
        var out: [ActivityEntry] = []
        for (mi, m) in margin.enumerated() {
            let h = pairs[mi].map { sortedHealth[$0.0] }
            let isStrength = m.strength != nil
            var title = WorkoutType.name(h?.activityType ?? m.type)
            if let s = m.strength {
                title = s.routineName ?? "Strength workout"
                var names: [String] = []
                for n in s.sets.compactMap({ exerciseName($0.exerciseID) }) where !names.contains(n) { names.append(n) }
                if !names.isEmpty, s.routineName == nil { title = "Strength: " + names.prefix(3).joined(separator: ", ") }
            }
            out.append(ActivityEntry(id: h.map(healthKey) ?? "margin-\(m.id.uuidString)", kind: isStrength ? .strength : .logged,
                                     activityType: h?.activityType ?? m.type, start: h?.start ?? m.start, end: h?.end ?? m.end,
                                     title: title, health: h, logged: m.logged, strength: m.strength, match: pairs[mi]?.1))
        }
        for (hi, w) in sortedHealth.enumerated() where !usedHealth.contains(hi) {
            out.append(ActivityEntry(id: healthKey(w), kind: .healthWorkout, activityType: w.activityType, start: w.start, end: w.end,
                                     title: WorkoutType.name(w.activityType), health: w, logged: nil, strength: nil, match: nil))
        }
        return out.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
}
