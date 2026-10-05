import XCTest
@testable import MarginCore

/// Activity reconciliation (Health ↔ Margin logs) and timeline identity,
/// ordering, de-duplication and late/corrected/deleted data.
final class TimelineTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }
    var evening: Date { at(today, 21) }

    func workout(_ type: UInt, _ h: Int, _ m: Int, minutes: Double, id: UUID? = UUID()) -> WorkoutDetail {
        var w = WorkoutDetail(start: at(today, h, m), end: at(today, h, m).addingTimeInterval(minutes * 60), activityType: type)
        w.healthID = id
        return w
    }

    func session(_ h: Int, _ m: Int, minutes: Double, healthID: UUID? = nil) -> StrengthSession {
        let s = at(today, h, m)
        return StrengthSession(start: s, end: s.addingTimeInterval(minutes * 60),
                               sets: [StrengthSet(exerciseID: "bench-press", date: s.addingTimeInterval(60), weightKg: 80, reps: 5)],
                               healthWorkoutID: healthID)
    }

    // MARK: Reconciliation

    func testUUIDMatchMergesOneSessionWithItsHealthWorkout() {
        let id = UUID()
        let entries = ActivityReconciler.reconcile(health: [workout(50, 18, 0, minutes: 60, id: id)], logged: [],
                                                   strength: [session(18, 0, minutes: 60, healthID: id)])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .strength)
        XCTAssertEqual(entries[0].match, .healthID)
        XCTAssertEqual(entries[0].id, "hk-\(id.uuidString)")
        XCTAssertNotNil(entries[0].health)
    }

    func testLegacyTimeOverlapRule() {
        // No stored UUID: starts 60 s apart and overlaps fully -> same workout.
        let merged = ActivityReconciler.reconcile(health: [workout(50, 18, 1, minutes: 58)], logged: [],
                                                  strength: [session(18, 0, minutes: 60)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].match, .timeOverlap)
        // Starts 5 min apart -> kept separate.
        let apart = ActivityReconciler.reconcile(health: [workout(50, 18, 5, minutes: 55)], logged: [],
                                                 strength: [session(18, 0, minutes: 60)])
        XCTAssertEqual(apart.count, 2)
        // Different activity family -> never merged.
        let run = ActivityReconciler.reconcile(health: [workout(37, 18, 0, minutes: 60)], logged: [],
                                               strength: [session(18, 0, minutes: 60)])
        XCTAssertEqual(run.count, 2)
        // A log that stores a UUID never falls back to time matching.
        let wrongID = ActivityReconciler.reconcile(health: [workout(50, 18, 0, minutes: 60)], logged: [],
                                                   strength: [session(18, 0, minutes: 60, healthID: UUID())])
        XCTAssertEqual(wrongID.count, 2)
    }

    func testEachHealthWorkoutMatchesAtMostOneLog() {
        let w = workout(37, 7, 0, minutes: 40)
        let a = LoggedActivity(activityType: 37, start: at(today, 7, 0), end: at(today, 7, 40), origin: .manual)
        let b = LoggedActivity(activityType: 37, start: at(today, 7, 1), end: at(today, 7, 39), origin: .manual)
        let entries = ActivityReconciler.reconcile(health: [w], logged: [a, b], strength: [])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.filter { $0.health != nil }.count, 1)
    }

    func testIdentitiesAreStableAcrossSyncs() {
        let id = UUID()
        let gym = session(18, 0, minutes: 60)
        let base = ActivityReconciler.reconcile(health: [workout(37, 7, 0, minutes: 40, id: id)], logged: [], strength: [gym])
        // A late-arriving Health workout must not change existing identities.
        let later = ActivityReconciler.reconcile(health: [workout(37, 7, 0, minutes: 40, id: id), workout(52, 12, 0, minutes: 20)],
                                                 logged: [], strength: [gym])
        XCTAssertTrue(Set(base.map(\.id)).isSubset(of: Set(later.map(\.id))))
        XCTAssertEqual(later.count, 3)
        XCTAssertEqual(later.map(\.start), later.map(\.start).sorted())
    }

    func testLoggingDetectsAnExistingHealthWorkout() {
        let w = workout(37, 7, 0, minutes: 40)
        XCTAssertEqual(ActivityReconciler.existingWorkout(type: 37, start: at(today, 7, 5), end: at(today, 7, 35), in: [w])?.healthID, w.healthID)
        XCTAssertNil(ActivityReconciler.existingWorkout(type: 37, start: at(today, 9, 0), end: at(today, 9, 30), in: [w]))
        XCTAssertNil(ActivityReconciler.existingWorkout(type: 13, start: at(today, 7, 5), end: at(today, 7, 35), in: [w]),
                     "a ride is not the run that overlaps it")
        XCTAssertEqual(LoggedActivity(activityType: 37, start: at(today, 7), end: at(today, 7, 40), rpe: 6, origin: .manual).sessionLoad, 240)
    }

    // MARK: Timeline

    func pipeline(input: RawDayInput) -> PipelineHarness {
        var h = PipelineHarness()
        h.sync(today: today, now: evening, input: input)
        return h
    }

    func rawInput(workoutID: UUID?) -> RawDayInput {
        let days = Day.range(from: today.adding(-20, calendar: cal), to: today, calendar: cal)
        var input = RawFixture.input(days: days, spec: { _ in NightSpec() })
        input.workouts = input.workouts.map { WorkoutSample(start: $0.start, end: $0.end, activityType: 50, healthID: Day($0.start, calendar: cal) == today ? workoutID : UUID()) }
        return input
    }

    func timeline(_ h: PipelineHarness, strength: StrengthLog? = nil, bio: BiomarkerInput? = nil, status: [StatusPeriod] = []) -> DayTimeline {
        Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male), calendar: cal,
               asOf: evening, statusPeriods: status)
            .brief(biomarkers: bio, strength: strength, generatedAt: evening).timelines!.last!
    }

    func testSavedStrengthSessionAppearsOnce() {
        let id = UUID()
        let h = pipeline(input: rawInput(workoutID: id))
        let w = h.records[today]!.workoutDetails[0]
        let s = StrengthSession(start: w.start, end: w.end,
                                sets: [StrengthSet(exerciseID: "bench-press", date: w.start.addingTimeInterval(60), weightKg: 80, reps: 5)],
                                healthWorkoutID: id)
        let t = timeline(h, strength: StrengthLog(sessions: [s]))
        let workouts = t.items.filter { [.workout, .strength, .activity].contains($0.kind) }
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].kind, .strength)
        XCTAssertEqual(workouts[0].source, "Margin + Apple Health")
        XCTAssertEqual(Set(t.items.map(\.id)).count, t.items.count, "ids are unique")
        XCTAssertEqual(t.items.map(\.date), t.items.map(\.date).sorted())
    }

    func testDeletedHealthWorkoutDisappearsAndLateDataAppears() {
        var input = rawInput(workoutID: UUID())
        let h1 = pipeline(input: input)
        XCTAssertEqual(timeline(h1).items.filter { $0.kind == .workout }.count, 1)
        input.workouts.removeAll { Day($0.start, calendar: cal) == today }
        var h2 = h1
        h2.sync(today: today, now: evening, input: input)
        XCTAssertEqual(timeline(h2).items.filter { $0.kind == .workout }.count, 0, "rebuilt from Health, so the deleted workout is gone")

        var bio = BiomarkerInput()
        let t1 = timeline(h2, bio: bio).items.filter { $0.kind == .measurement }
        XCTAssertTrue(t1.isEmpty)
        bio[.bodyMass] = [TimedValue(start: at(today, 7, 30), end: at(today, 7, 30), value: 80.4, source: "Scale")]
        let added = timeline(h2, bio: bio).items.filter { $0.kind == .measurement }
        XCTAssertEqual(added.map(\.detail), ["80.4 kg"])
        XCTAssertEqual(added.first?.source, "Scale")
        // A corrected reading (same time, new value) keeps its identity.
        bio[.bodyMass] = [TimedValue(start: at(today, 7, 30), end: at(today, 7, 30), value: 80.1, source: "Scale")]
        let corrected = timeline(h2, bio: bio).items.filter { $0.kind == .measurement }
        XCTAssertEqual(corrected.map(\.id), added.map(\.id))
        XCTAssertEqual(corrected.map(\.detail), ["80.1 kg"])
    }

    func testVitalsRecoveryStrainAndStatusEvents() throws {
        let h = pipeline(input: rawInput(workoutID: UUID()))
        let status = [StatusPeriod(kind: .travel, start: today.adding(-3, calendar: cal), end: today.adding(-1, calendar: cal))]
        let t = timeline(h, status: status)
        let vitals = try XCTUnwrap(t.items.first { $0.kind == .vitals })
        XCTAssertTrue(vitals.detail.contains("HRV 55 ms (3 readings)"))
        XCTAssertTrue(vitals.detail.contains("respiration 14.0/min"))
        XCTAssertTrue(t.items.contains { $0.kind == .recovery })
        let strain = t.items.filter { $0.kind == .strain }.map(\.title)
        XCTAssertEqual(strain, strain.sorted())
        XCTAssertLessThanOrEqual(strain.count, 3)
        XCTAssertTrue(t.items.contains { $0.id.hasSuffix("-end") && $0.title == "Travel ended" })
    }

    func testOldTimelineItemsDecodeWithoutIDs() throws {
        let json = Data(#"{"date":0,"kind":"wake","title":"Woke","detail":""}"#.utf8)
        let item = try JSONDecoder().decode(TimelineItem.self, from: json)
        XCTAssertEqual(item.kind, .wake)
        XCTAssertFalse(item.id.isEmpty)
    }

    func testOrderingIsDeterministicForSimultaneousEvents() {
        let t0 = at(today, 7)
        let items = [TimelineItem(id: "b", date: t0, kind: .recovery, title: "", detail: ""),
                     TimelineItem(id: "a", date: t0, kind: .wake, title: "", detail: ""),
                     TimelineItem(id: "a", date: t0, kind: .wake, title: "dup", detail: "")]
        let ordered = TimelineItem.ordered(items)
        XCTAssertEqual(ordered.map(\.id), ["a", "b"], "wake before recovery; duplicate ids dropped")
    }
}
