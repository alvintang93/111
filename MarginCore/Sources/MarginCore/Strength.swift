import Foundation

// MARK: - Log

public struct StrengthSet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var exerciseID: String
    public var date: Date
    /// External weight in kg (for bodyweight movements: added weight).
    public var weightKg: Double
    public var reps: Int
    /// Rate of perceived exertion, 1-10. Nil when not entered.
    public var rpe: Double?
    public var warmup: Bool

    public init(id: UUID = UUID(), exerciseID: String, date: Date, weightKg: Double, reps: Int, rpe: Double? = nil,
                warmup: Bool = false) {
        self.id = id
        self.exerciseID = exerciseID
        self.date = date
        self.weightKg = weightKg
        self.reps = reps
        self.rpe = rpe
        self.warmup = warmup
    }
}

public struct StrengthSession: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var start: Date
    public var end: Date?
    public var sets: [StrengthSet]
    /// True once the workout was saved to Health.
    public var savedToHealth: Bool

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, sets: [StrengthSet] = [], savedToHealth: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.sets = sets
        self.savedToHealth = savedToHealth
    }
}

public struct StrengthLog: Codable, Sendable, Equatable {
    public var sessions: [StrengthSession]
    public var customExercises: [Exercise]

    public init(sessions: [StrengthSession] = [], customExercises: [Exercise] = []) {
        self.sessions = sessions
        self.customExercises = customExercises
    }

    public func exercise(_ id: String) -> Exercise? {
        ExerciseLibrary.byID[id] ?? customExercises.first { $0.id == id }
    }

    /// Every working set, oldest first.
    public var workingSets: [StrengthSet] {
        sessions.flatMap(\.sets).filter { !$0.warmup }.sorted { $0.date < $1.date }
    }

    /// The most recent set of an exercise: used to pre-fill the next set.
    public func lastSet(of exerciseID: String) -> StrengthSet? {
        sessions.flatMap(\.sets).filter { $0.exerciseID == exerciseID && !$0.warmup }.max { $0.date < $1.date }
    }

    /// Exercises by most recent use.
    public func recentExerciseIDs(limit: Int = 8) -> [String] {
        var seen: [String] = []
        for s in sessions.flatMap(\.sets).sorted(by: { $0.date > $1.date }) where !seen.contains(s.exerciseID) {
            seen.append(s.exerciseID)
            if seen.count == limit { break }
        }
        return seen
    }
}

// MARK: - Models

public enum StrengthModel {
    /// Epley estimate. Reps above 12 are capped (the estimate degrades), 1 rep = the weight.
    public static func e1RM(weightKg: Double, reps: Int) -> Double {
        guard reps > 0, weightKg > 0 else { return 0 }
        if reps == 1 { return weightKg }
        return weightKg * (1 + Double(min(reps, 12)) / 30)
    }

    /// Load actually moved per rep: external weight plus the body-mass share for bodyweight movements.
    public static func effectiveLoad(_ set: StrengthSet, exercise: Exercise?, bodyMassKg: Double) -> Double {
        set.weightKg + (exercise?.bodyweightFactor ?? 0) * bodyMassKg
    }

    /// Effort weight of a set: 1 without RPE; with RPE, (RPE − 5)/5 clamped to 0.2...1,
    /// so a set far from failure counts less than a hard one.
    public static func effort(_ set: StrengthSet) -> Double {
        guard let r = set.rpe else { return 1 }
        return Stats.clamp((r - 5) / 5, 0.2, 1)
    }

    /// Hard-set equivalents per muscle for a set: primary muscles 1.0, secondary 0.5, times effort.
    public static func muscleStimulus(_ set: StrengthSet, exercise: Exercise) -> [Muscle: Double] {
        guard !set.warmup, set.reps > 0 else { return [:] }
        let e = effort(set)
        var out: [Muscle: Double] = [:]
        for m in exercise.primary { out[m, default: 0] += e }
        for m in exercise.secondary where !exercise.primary.contains(m) { out[m, default: 0] += 0.5 * e }
        return out
    }

    /// Residual fatigue in hard-set equivalents, each set decaying with the muscle's time constant.
    public static func fatigue(_ muscle: Muscle, sets: [StrengthSet], log: StrengthLog, at t: Date) -> Double {
        let tau = muscle.recoveryHours * 3600
        return sets.reduce(0) { acc, s in
            guard s.date <= t, let ex = log.exercise(s.exerciseID), let x = muscleStimulus(s, exercise: ex)[muscle] else { return acc }
            return acc + x * exp(-t.timeIntervalSince(s.date) / tau)
        }
    }

    /// Hard-set equivalents of fatigue that map to freshness 37 (1/e).
    public static let fatigueScale = 6.0
    /// Freshness at or above this counts as ready to train the muscle again.
    public static let readyFreshness = 80.0

    public static func freshness(fatigue: Double) -> Double {
        100 * exp(-max(fatigue, 0) / fatigueScale)
    }

    /// When freshness reaches `readyFreshness`, assuming no more training. Nil if already ready.
    public static func readyAt(_ muscle: Muscle, fatigue f: Double, now: Date) -> Date? {
        let threshold = -fatigueScale * log(readyFreshness / 100)
        guard f > threshold else { return nil }
        return now.addingTimeInterval(muscle.recoveryHours * 3600 * log(f / threshold))
    }
}

/// Plates per side for a target barbell weight.
public struct PlateLoadout: Sendable, Equatable {
    public var perSide: [Double]
    /// Total the loadout makes (≤ target when the target cannot be hit exactly).
    public var achieved: Double
    public var exact: Bool
}

public enum PlateCalculator {
    public static let kgPlates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    public static let lbPlates: [Double] = [45, 35, 25, 10, 5, 2.5]

    /// Greedy from the heaviest plate, which is optimal for standard plate sets.
    public static func load(target: Double, bar: Double, plates: [Double]) -> PlateLoadout {
        var side = max(0, (target - bar) / 2)
        var out: [Double] = []
        for p in plates.sorted(by: >) {
            while side + 1e-9 >= p {
                out.append(p)
                side -= p
            }
        }
        let achieved = bar + 2 * out.reduce(0, +)
        return PlateLoadout(perSide: out, achieved: max(achieved, bar), exact: abs(achieved - target) < 1e-6)
    }
}

// MARK: - Summary for the brief

public struct MuscleStatus: Codable, Sendable, Equatable, Identifiable {
    public var muscle: Muscle
    public var freshness: Int
    public var readyAt: Date?
    /// Hard-set equivalents over the last 7 days.
    public var weeklySets: Double
    public var id: String { muscle.rawValue }
}

public struct PersonalRecord: Codable, Sendable, Equatable, Identifiable {
    public var exerciseID: String
    public var name: String
    public var e1RM: Double
    public var weightKg: Double
    public var reps: Int
    public var date: Date
    public var id: String { exerciseID }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date?
    public var sets: Int
    /// Σ effective load × reps over working sets, kg.
    public var volumeKg: Double
    public var exercises: [String]
    /// Exercises whose best estimated 1RM was set in this session.
    public var newRecords: [String]
}

public struct StrengthSummary: Codable, Sendable, Equatable {
    public var muscles: [MuscleStatus]
    public var lastSession: SessionSummary?
    /// Best estimated 1RM per exercise, heaviest first.
    public var records: [PersonalRecord]
    public var sessionsLast7: Int
    /// The pinned lift (Today tile / complication), if it has been logged.
    public var pinnedLift: PersonalRecord?

    public static func make(log: StrengthLog, now: Date, bodyMassKg: Double, pinnedExerciseID: String?) -> StrengthSummary? {
        let sets = log.workingSets.filter { $0.date <= now }
        guard !sets.isEmpty else { return nil }
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let muscles = Muscle.allCases.map { m -> MuscleStatus in
            let f = StrengthModel.fatigue(m, sets: sets, log: log, at: now)
            let weekly = sets.filter { $0.date >= weekAgo }.reduce(0.0) { acc, s in
                guard let ex = log.exercise(s.exerciseID) else { return acc }
                return acc + (StrengthModel.muscleStimulus(s, exercise: ex)[m] ?? 0)
            }
            return MuscleStatus(muscle: m, freshness: Int(StrengthModel.freshness(fatigue: f).rounded()),
                                readyAt: StrengthModel.readyAt(m, fatigue: f, now: now), weeklySets: weekly)
        }
        var best: [String: PersonalRecord] = [:]
        // Best before each session, to flag records set in the last one.
        for s in sets {
            let ex = log.exercise(s.exerciseID)
            let load = StrengthModel.effectiveLoad(s, exercise: ex, bodyMassKg: bodyMassKg)
            let e = StrengthModel.e1RM(weightKg: load, reps: s.reps)
            if e > (best[s.exerciseID]?.e1RM ?? 0) {
                best[s.exerciseID] = PersonalRecord(exerciseID: s.exerciseID, name: ex?.name ?? s.exerciseID, e1RM: e,
                                                    weightKg: s.weightKg, reps: s.reps, date: s.date)
            }
        }
        let finished = log.sessions.filter { !$0.sets.isEmpty && $0.start <= now }.sorted { $0.start < $1.start }
        var last: SessionSummary?
        if let ls = finished.last {
            let working = ls.sets.filter { !$0.warmup }
            let volume = working.reduce(0.0) { acc, s in
                acc + StrengthModel.effectiveLoad(s, exercise: log.exercise(s.exerciseID), bodyMassKg: bodyMassKg) * Double(s.reps)
            }
            var names: [String] = []
            for s in working {
                let n = log.exercise(s.exerciseID)?.name ?? s.exerciseID
                if !names.contains(n) { names.append(n) }
            }
            // A record needs earlier history for the exercise: a first attempt is not a record.
            let records = best.values.filter { r in
                working.contains { $0.date == r.date && $0.exerciseID == r.exerciseID }
                    && sets.contains { $0.exerciseID == r.exerciseID && $0.date < ls.start }
            }.map(\.name).sorted()
            last = SessionSummary(start: ls.start, end: ls.end, sets: working.count, volumeKg: volume, exercises: names,
                                  newRecords: records)
        }
        return StrengthSummary(muscles: muscles, lastSession: last,
                               records: best.values.sorted { ($0.e1RM, $0.exerciseID) > ($1.e1RM, $1.exerciseID) },
                               sessionsLast7: finished.filter { $0.start >= weekAgo }.count,
                               pinnedLift: pinnedExerciseID.flatMap { best[$0] })
    }
}
