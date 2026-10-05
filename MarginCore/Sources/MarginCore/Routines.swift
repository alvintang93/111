import Foundation

/// Routines are templates for strength sessions. Starting one runs a normal
/// strength workout (same `StrengthSession`, sets, Health workout, muscle
/// freshness and load), tagged with the routine. There is no second strength
/// system.
public struct RoutineItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Sets of an exercise from the library (or a custom exercise).
        case exercise
        /// A timed block such as a warm-up row or a run, checked off when done.
        case activity
    }

    public var id: UUID
    public var kind: Kind
    public var exerciseID: String?
    /// `HKWorkoutActivityType.rawValue` for activity items.
    public var activityType: UInt?
    public var sets: Int
    public var reps: Int
    /// Target load. Nil means "use what you lifted last time".
    public var loadKg: Double?
    public var restSeconds: Int
    public var minutes: Int?
    public var notes: String

    public static func exercise(_ id: String, sets: Int = 3, reps: Int = 8, loadKg: Double? = nil, restSeconds: Int = 120) -> RoutineItem {
        RoutineItem(id: UUID(), kind: .exercise, exerciseID: id, activityType: nil, sets: sets, reps: reps, loadKg: loadKg,
                    restSeconds: restSeconds, minutes: nil, notes: "")
    }

    public static func activity(_ type: UInt, minutes: Int) -> RoutineItem {
        RoutineItem(id: UUID(), kind: .activity, exerciseID: nil, activityType: type, sets: 1, reps: 0, loadKg: nil,
                    restSeconds: 0, minutes: minutes, notes: "")
    }
}

public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var items: [RoutineItem]
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var archived: Bool

    public init(id: UUID = UUID(), name: String, items: [RoutineItem] = [], notes: String = "", createdAt: Date,
                updatedAt: Date? = nil, archived: Bool = false) {
        self.id = id
        self.name = name
        self.items = items
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.archived = archived
    }

    public var plannedSets: Int { items.filter { $0.kind == .exercise }.reduce(0) { $0 + $1.sets } }
}

public struct RoutineLibrary: Codable, Sendable, Equatable {
    public var routines: [Routine]
    /// Deletion times, so a delete on one device survives a merge with an older copy.
    public var deleted: [UUID: Date]?

    public init(routines: [Routine] = [], deleted: [UUID: Date]? = nil) {
        self.routines = routines
        self.deleted = deleted
    }

    /// Not archived, most recently changed first.
    public var active: [Routine] { routines.filter { !$0.archived }.sorted { ($0.updatedAt, $0.name) > ($1.updatedAt, $1.name) } }
    public var archived: [Routine] { routines.filter(\.archived).sorted { $0.name < $1.name } }

    public func routine(_ id: UUID) -> Routine? { routines.first { $0.id == id } }

    @discardableResult
    public mutating func create(name: String, items: [RoutineItem] = [], at date: Date) -> Routine {
        let r = Routine(name: Self.clean(name), items: items, createdAt: date)
        routines.append(r)
        return r
    }

    /// Replaces the stored routine with the same id. Blank names are kept as before.
    public mutating func update(_ routine: Routine, at date: Date) {
        guard let k = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        var r = routine
        r.name = Self.clean(routine.name).isEmpty ? routines[k].name : Self.clean(routine.name)
        r.createdAt = routines[k].createdAt
        r.updatedAt = date
        routines[k] = r
    }

    /// A copy with new ids (so the copy's history is separate), named "<name> copy".
    @discardableResult
    public mutating func duplicate(_ id: UUID, at date: Date) -> Routine? {
        guard let r = routine(id) else { return nil }
        var items = r.items
        for k in items.indices { items[k].id = UUID() }
        let copy = Routine(name: r.name + " copy", items: items, notes: r.notes, createdAt: date)
        routines.append(copy)
        return copy
    }

    public mutating func setArchived(_ id: UUID, _ archived: Bool, at date: Date) {
        guard let k = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[k].archived = archived
        routines[k].updatedAt = date
    }

    /// Deletes the template. Past sessions keep their sets and the routine name they were done under.
    public mutating func delete(_ id: UUID, at date: Date = Date()) {
        routines.removeAll { $0.id == id }
        var t = deleted ?? [:]
        t[id] = date
        deleted = t
    }

    public mutating func moveItem(_ itemID: UUID, in routineID: UUID, by offset: Int, at date: Date) {
        guard let k = routines.firstIndex(where: { $0.id == routineID }),
              let i = routines[k].items.firstIndex(where: { $0.id == itemID }) else { return }
        let j = min(max(i + offset, 0), routines[k].items.count - 1)
        guard i != j else { return }
        let item = routines[k].items.remove(at: i)
        routines[k].items.insert(item, at: j)
        routines[k].updatedAt = date
    }

    static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// One planned set (or activity block) when running a routine.
public struct RoutineTarget: Codable, Sendable, Equatable, Identifiable {
    public var itemID: UUID
    public var kind: RoutineItem.Kind
    public var exerciseID: String?
    public var activityType: UInt?
    /// 1-based.
    public var setNumber: Int
    public var setCount: Int
    public var reps: Int
    public var weightKg: Double?
    public var restSeconds: Int
    public var minutes: Int?
    /// Where the weight came from: "routine target", "last time in this routine", "your last set".
    public var weightSource: String?
    public var id: String { "\(itemID.uuidString)-\(setNumber)" }
}

public struct RoutineProgress: Sendable, Equatable {
    public var completedSets: [UUID: Int]
    public var next: RoutineTarget?
    public var done: Bool
    public var completedFraction: Double
}

public enum RoutineRunner {
    /// Every planned set in order, with weights pre-filled: the routine's own
    /// target, else what you lifted for that item the last time you ran this
    /// routine, else your last working set of the exercise.
    public static func targets(for routine: Routine, log: StrengthLog) -> [RoutineTarget] {
        let previous = history(routine.id, log: log).last
        var out: [RoutineTarget] = []
        for item in routine.items {
            switch item.kind {
            case .activity:
                out.append(RoutineTarget(itemID: item.id, kind: .activity, exerciseID: nil, activityType: item.activityType, setNumber: 1,
                                         setCount: 1, reps: 0, weightKg: nil, restSeconds: 0, minutes: item.minutes, weightSource: nil))
            case .exercise:
                guard let ex = item.exerciseID else { continue }
                let lastInRoutine = previous?.sets.filter { $0.exerciseID == ex && !$0.warmup } ?? []
                for n in 1...max(item.sets, 1) {
                    var weight = item.loadKg
                    var source: String? = weight == nil ? nil : "routine target"
                    if weight == nil, !lastInRoutine.isEmpty {
                        weight = lastInRoutine[min(n, lastInRoutine.count) - 1].weightKg
                        source = "last time in this routine"
                    }
                    if weight == nil, let last = log.lastSet(of: ex) {
                        weight = last.weightKg
                        source = "your last set"
                    }
                    out.append(RoutineTarget(itemID: item.id, kind: .exercise, exerciseID: ex, activityType: nil, setNumber: n,
                                             setCount: max(item.sets, 1), reps: item.reps, weightKg: weight, restSeconds: item.restSeconds,
                                             minutes: nil, weightSource: source))
                }
            }
        }
        return out
    }

    /// Progress of a session against its routine. Working sets count toward
    /// the item with the same exercise, in order; activity items count when checked off.
    public static func progress(_ routine: Routine, session: StrengthSession, log: StrengthLog) -> RoutineProgress {
        var remaining: [String: Int] = [:]
        for s in session.sets where !s.warmup { remaining[s.exerciseID, default: 0] += 1 }
        var completed: [UUID: Int] = [:]
        for item in routine.items {
            switch item.kind {
            case .exercise:
                guard let ex = item.exerciseID else { continue }
                let n = min(remaining[ex] ?? 0, max(item.sets, 1))
                completed[item.id] = n
                remaining[ex] = (remaining[ex] ?? 0) - n
            case .activity:
                completed[item.id] = (session.completedItems ?? []).contains(item.id) ? 1 : 0
            }
        }
        let all = targets(for: routine, log: log)
        let next = all.first { t in (completed[t.itemID] ?? 0) < t.setNumber }
        let total = all.count
        let doneCount = all.filter { (completed[$0.itemID] ?? 0) >= $0.setNumber }.count
        return RoutineProgress(completedSets: completed, next: next, done: next == nil && total > 0,
                               completedFraction: total > 0 ? Double(doneCount) / Double(total) : 0)
    }

    /// Sessions run from this routine, oldest first.
    public static func history(_ routineID: UUID, log: StrengthLog) -> [StrengthSession] {
        log.sessions.filter { $0.routineID == routineID && !$0.sets.isEmpty }.sorted { $0.start < $1.start }
    }
}
