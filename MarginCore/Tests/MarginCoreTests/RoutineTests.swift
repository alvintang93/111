import XCTest
@testable import MarginCore

/// Routines: library operations, persistence, pre-filled targets, progress,
/// completion and their integration with strength sessions.
final class RoutineTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }
    var t0: Date { at(today, 8) }

    func push() -> Routine {
        Routine(name: "Push A", items: [.exercise("bench-press", sets: 3, reps: 5), .exercise("overhead-press", sets: 2, reps: 8, loadKg: 40),
                                       .activity(35, minutes: 10)], createdAt: t0)
    }

    func testCreateEditDuplicateArchiveDelete() throws {
        var lib = RoutineLibrary()
        let r = lib.create(name: "  Legs  ", items: [.exercise("back-squat")], at: t0)
        XCTAssertEqual(r.name, "Legs")
        var edited = r
        edited.name = "Legs heavy"
        edited.items.append(.exercise("romanian-deadlift"))
        lib.update(edited, at: t0.addingTimeInterval(60))
        XCTAssertEqual(lib.routine(r.id)?.items.count, 2)
        XCTAssertEqual(lib.routine(r.id)?.createdAt, t0, "creation date is kept")
        var blank = lib.routine(r.id)!
        blank.name = "   "
        lib.update(blank, at: t0.addingTimeInterval(90))
        XCTAssertEqual(lib.routine(r.id)?.name, "Legs heavy", "a blank name is not saved")

        let copy = try XCTUnwrap(lib.duplicate(r.id, at: t0.addingTimeInterval(120)))
        XCTAssertEqual(copy.name, "Legs heavy copy")
        XCTAssertNotEqual(copy.id, r.id)
        XCTAssertTrue(Set(copy.items.map(\.id)).isDisjoint(with: Set(lib.routine(r.id)!.items.map(\.id))))
        XCTAssertEqual(lib.active.first?.id, copy.id, "most recently changed first")

        lib.setArchived(r.id, true, at: t0.addingTimeInterval(180))
        XCTAssertEqual(lib.active.map(\.id), [copy.id])
        XCTAssertEqual(lib.archived.map(\.id), [r.id])
        lib.delete(copy.id)
        XCTAssertNil(lib.routine(copy.id))
        XCTAssertEqual(lib.routines.count, 1)
    }

    func testReorderingItems() {
        var lib = RoutineLibrary(routines: [push()])
        let r = lib.routines[0]
        lib.moveItem(r.items[2].id, in: r.id, by: -2, at: t0)
        XCTAssertEqual(lib.routines[0].items.map(\.kind), [.activity, .exercise, .exercise])
        lib.moveItem(r.items[2].id, in: r.id, by: -5, at: t0)
        XCTAssertEqual(lib.routines[0].items.first?.id, r.items[2].id, "moves are clamped")
    }

    func testPersistenceRoundTrip() throws {
        let lib = RoutineLibrary(routines: [push()])
        XCTAssertEqual(try JSONDecoder().decode(RoutineLibrary.self, from: JSONEncoder().encode(lib)), lib)
        // Sessions saved before routines existed still decode.
        let old = Data(#"{"sessions":[{"id":"6A1E4C3E-1D5B-4C1C-9C5A-0F3C2E1B7A11","start":0,"sets":[],"savedToHealth":false}],"customExercises":[]}"#.utf8)
        let log = try JSONDecoder().decode(StrengthLog.self, from: old)
        XCTAssertNil(log.sessions[0].routineID)
        XCTAssertNil(log.sessions[0].healthWorkoutID)
    }

    func testTargetsPrefillFromRoutineHistoryThenLastSet() {
        let r = push()
        var log = StrengthLog(sessions: [StrengthSession(start: at(today.adding(-10, calendar: cal), 8), sets: [
            StrengthSet(exerciseID: "bench-press", date: at(today.adding(-10, calendar: cal), 8), weightKg: 70, reps: 5),
        ])])
        var targets = RoutineRunner.targets(for: r, log: log)
        XCTAssertEqual(targets.count, 3 + 2 + 1)
        XCTAssertEqual(targets[0].weightKg, 70)
        XCTAssertEqual(targets[0].weightSource, "your last set")
        XCTAssertEqual(targets[3].weightKg, 40)
        XCTAssertEqual(targets[3].weightSource, "routine target")

        let d = at(today.adding(-3, calendar: cal), 8)
        log.sessions.append(StrengthSession(start: d, sets: [
            StrengthSet(exerciseID: "bench-press", date: d, weightKg: 80, reps: 5),
            StrengthSet(exerciseID: "bench-press", date: d.addingTimeInterval(120), weightKg: 82.5, reps: 5),
            StrengthSet(exerciseID: "bench-press", date: d.addingTimeInterval(240), weightKg: 82.5, reps: 4),
        ], routineID: r.id, routineName: r.name))
        targets = RoutineRunner.targets(for: r, log: log)
        XCTAssertEqual(targets.prefix(3).map(\.weightKg), [80, 82.5, 82.5])
        XCTAssertEqual(targets[0].weightSource, "last time in this routine")
    }

    func testProgressAndCompletion() {
        let r = push()
        let log = StrengthLog()
        var s = StrengthSession(start: t0, routineID: r.id, routineName: r.name)
        var p = RoutineRunner.progress(r, session: s, log: log)
        XCTAssertEqual(p.next?.exerciseID, "bench-press")
        XCTAssertEqual(p.next?.setNumber, 1)
        XCTAssertFalse(p.done)

        s.sets.append(StrengthSet(exerciseID: "bench-press", date: t0, weightKg: 60, reps: 10, warmup: true))
        XCTAssertEqual(RoutineRunner.progress(r, session: s, log: log).next?.setNumber, 1, "warm-ups don't count")
        for k in 0..<3 { s.sets.append(StrengthSet(exerciseID: "bench-press", date: t0.addingTimeInterval(Double(k)), weightKg: 80, reps: 5)) }
        for k in 0..<2 { s.sets.append(StrengthSet(exerciseID: "overhead-press", date: t0.addingTimeInterval(Double(10 + k)), weightKg: 40, reps: 8)) }
        p = RoutineRunner.progress(r, session: s, log: log)
        XCTAssertEqual(p.next?.kind, .activity)
        XCTAssertEqual(p.completedFraction, 5.0 / 6.0, accuracy: 1e-12)
        s.completedItems = [r.items[2].id]
        p = RoutineRunner.progress(r, session: s, log: log)
        XCTAssertTrue(p.done)
        XCTAssertNil(p.next)
        // An extra set beyond the plan doesn't break completion.
        s.sets.append(StrengthSet(exerciseID: "bench-press", date: t0.addingTimeInterval(99), weightKg: 80, reps: 5))
        XCTAssertTrue(RoutineRunner.progress(r, session: s, log: log).done)
    }

    func testCompletedRoutineFeedsHistoryFreshnessAndTimelineOnce() {
        let r = push()
        let id = UUID()
        let session = StrengthSession(start: at(today, 18), end: at(today, 19), sets: [
            StrengthSet(exerciseID: "bench-press", date: at(today, 18, 5), weightKg: 80, reps: 5),
        ], savedToHealth: true, healthWorkoutID: id, routineID: r.id, routineName: r.name)
        let log = StrengthLog(sessions: [session])
        XCTAssertEqual(RoutineRunner.history(r.id, log: log).map(\.id), [session.id])
        let summary = StrengthSummary.make(log: log, now: at(today, 20), bodyMassKg: 80, pinnedExerciseID: nil)!
        XCTAssertGreaterThan(summary.muscles.first { $0.muscle == .chest }!.weeklySets, 0)
        var w = WorkoutDetail(start: at(today, 18), end: at(today, 19), activityType: 50)
        w.healthID = id
        let entries = ActivityReconciler.reconcile(health: [w], logged: [], strength: [session])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "Push A")
    }
}
