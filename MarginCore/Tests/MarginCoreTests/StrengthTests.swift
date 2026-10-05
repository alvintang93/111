import XCTest
@testable import MarginCore

/// Batch 3: exercise library, set logging, estimated 1RM, plate calculator,
/// muscle stimulus, freshness and the strength summary.
final class StrengthTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }

    func set(_ id: String, _ kg: Double, _ reps: Int, at d: Date, rpe: Double? = nil, warmup: Bool = false) -> StrengthSet {
        StrengthSet(exerciseID: id, date: d, weightKg: kg, reps: reps, rpe: rpe, warmup: warmup)
    }

    func testLibraryIsConsistent() {
        let ids = ExerciseLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "unique IDs")
        XCTAssertGreaterThanOrEqual(ids.count, 110)
        for e in ExerciseLibrary.all {
            XCTAssertFalse(e.primary.isEmpty, e.id)
            XCTAssertTrue(Set(e.primary).isDisjoint(with: e.secondary), e.id)
        }
        for m in Muscle.allCases {
            XCTAssertGreaterThanOrEqual(ExerciseLibrary.exercises(for: m).count, 3, "\(m) needs at least 3 exercises")
        }
    }

    func testEstimatedOneRepMax() {
        XCTAssertEqual(StrengthModel.e1RM(weightKg: 100, reps: 1), 100)
        XCTAssertEqual(StrengthModel.e1RM(weightKg: 100, reps: 5), 100 * (1 + 5.0 / 30), accuracy: 1e-9)
        XCTAssertEqual(StrengthModel.e1RM(weightKg: 50, reps: 20), StrengthModel.e1RM(weightKg: 50, reps: 12), "capped at 12 reps")
        XCTAssertEqual(StrengthModel.e1RM(weightKg: 0, reps: 5), 0)
    }

    func testPlateCalculator() {
        let k = PlateCalculator.load(target: 100, bar: 20, plates: PlateCalculator.kgPlates)
        XCTAssertEqual(k.perSide, [25, 15])
        XCTAssertTrue(k.exact)
        let odd = PlateCalculator.load(target: 101, bar: 20, plates: PlateCalculator.kgPlates)
        XCTAssertEqual(odd.achieved, 100)
        XCTAssertFalse(odd.exact)
        XCTAssertEqual(PlateCalculator.load(target: 225, bar: 45, plates: PlateCalculator.lbPlates).perSide, [45, 45])
        XCTAssertEqual(PlateCalculator.load(target: 10, bar: 20, plates: PlateCalculator.kgPlates).achieved, 20, "below the bar")
        XCTAssertEqual(PlateCalculator.load(target: 22.5, bar: 20, plates: PlateCalculator.kgPlates).perSide, [1.25])
    }

    func testStimulusRolesEffortAndWarmups() {
        let bench = ExerciseLibrary.byID["bench-press"]!
        let s = StrengthModel.muscleStimulus(set("bench-press", 80, 8, at: at(today, 9)), exercise: bench)
        XCTAssertEqual(s[.chest], 1)
        XCTAssertEqual(s[.triceps], 0.5)
        XCTAssertNil(s[.quads])
        let easy = StrengthModel.muscleStimulus(set("bench-press", 80, 8, at: at(today, 9), rpe: 6), exercise: bench)
        XCTAssertEqual(easy[.chest]!, 0.2, accuracy: 1e-12)
        XCTAssertTrue(StrengthModel.muscleStimulus(set("bench-press", 40, 10, at: at(today, 9), warmup: true), exercise: bench).isEmpty)
        let pushUp = ExerciseLibrary.byID["push-up"]!
        XCTAssertEqual(StrengthModel.effectiveLoad(set("push-up", 0, 10, at: at(today, 9)), exercise: pushUp, bodyMassKg: 80),
                       0.64 * 80, accuracy: 1e-9)
    }

    func testFreshnessDecaysAndReadyTimeIsConsistent() throws {
        let log = StrengthLog(sessions: [StrengthSession(start: at(today, 9), sets: (0..<6).map { _ in set("leg-extension", 50, 10, at: at(today, 9)) })])
        let now = at(today, 10)
        let f = StrengthModel.fatigue(.quads, sets: log.workingSets, log: log, at: now)
        XCTAssertEqual(f, 6 * exp(-1.0 / 30), accuracy: 1e-9)
        let fresh = StrengthModel.freshness(fatigue: f)
        XCTAssertLessThan(fresh, 50)
        let ready = try XCTUnwrap(StrengthModel.readyAt(.quads, fatigue: f, now: now))
        let fAtReady = StrengthModel.fatigue(.quads, sets: log.workingSets, log: log, at: ready)
        XCTAssertEqual(StrengthModel.freshness(fatigue: fAtReady), StrengthModel.readyFreshness, accuracy: 1e-6)
        XCTAssertEqual(StrengthModel.fatigue(.chest, sets: log.workingSets, log: log, at: now), 0)
        XCTAssertNil(StrengthModel.readyAt(.chest, fatigue: 0, now: now))
        // Smaller muscles recover faster from the same work.
        XCTAssertLessThan(Muscle.biceps.recoveryHours, Muscle.quads.recoveryHours)
    }

    func testSummaryRecordsVolumeAndWeeklySets() throws {
        let d1 = at(today.adding(-5, calendar: cal), 18), d2 = at(today, 18)
        let log = StrengthLog(sessions: [
            StrengthSession(start: d1, end: d1.addingTimeInterval(3600), sets: [
                set("bench-press", 80, 5, at: d1), set("bench-press", 80, 5, at: d1.addingTimeInterval(180)),
                set("squat-not-in-library", 100, 5, at: d1.addingTimeInterval(300)),
            ]),
            StrengthSession(start: d2, end: d2.addingTimeInterval(3600), sets: [
                set("bench-press", 40, 10, at: d2, warmup: true),
                set("bench-press", 85, 5, at: d2.addingTimeInterval(120)),
                set("pull-up", 0, 8, at: d2.addingTimeInterval(400)),
            ]),
        ])
        let s = try XCTUnwrap(StrengthSummary.make(log: log, now: at(today, 20), bodyMassKg: 80, pinnedExerciseID: "bench-press"))
        let last = try XCTUnwrap(s.lastSession)
        XCTAssertEqual(last.sets, 2, "warm-ups are not working sets")
        XCTAssertEqual(last.volumeKg, 85 * 5 + 80 * 8, accuracy: 1e-9, "pull-up moves body mass")
        XCTAssertEqual(last.newRecords, ["Bench press"], "a first-ever pull-up is not a record")
        XCTAssertEqual(s.pinnedLift?.e1RM ?? 0, StrengthModel.e1RM(weightKg: 85, reps: 5), accuracy: 1e-9)
        XCTAssertEqual(s.sessionsLast7, 2)
        let chest = s.muscles.first { $0.muscle == .chest }!
        XCTAssertEqual(chest.weeklySets, 3, accuracy: 1e-9)
        XCTAssertEqual(s.muscles.first { $0.muscle == .lats }!.weeklySets, 1, accuracy: 1e-9)
        XCTAssertEqual(s.records.first?.exerciseID, "squat-not-in-library", "unknown IDs still keep their records")
        XCTAssertNil(StrengthSummary.make(log: StrengthLog(), now: at(today, 20), bodyMassKg: 80, pinnedExerciseID: nil))
    }

    func testAutofillUsesTheLastWorkingSet() {
        let d = at(today, 18)
        let log = StrengthLog(sessions: [StrengthSession(start: d, sets: [
            set("db-curl", 12, 10, at: d), set("db-curl", 14, 8, at: d.addingTimeInterval(120)),
            set("db-curl", 6, 15, at: d.addingTimeInterval(240), warmup: true),
            set("lateral-raise", 8, 12, at: d.addingTimeInterval(400)),
        ])])
        XCTAssertEqual(log.lastSet(of: "db-curl")?.weightKg, 14)
        XCTAssertNil(log.lastSet(of: "bench-press"))
        XCTAssertEqual(log.recentExerciseIDs(), ["lateral-raise", "db-curl"])
    }

    func testCustomExercisesResolve() {
        let custom = Exercise("custom-landmine", "Landmine press", .barbell, [.frontDelts], [.chest])
        let log = StrengthLog(customExercises: [custom])
        XCTAssertEqual(log.exercise("custom-landmine")?.name, "Landmine press")
        XCTAssertEqual(log.exercise("bench-press")?.name, "Bench press")
    }

    func testWeightUnits() {
        XCTAssertEqual(WeightUnit.lb.display(100), 220.462, accuracy: 0.001)
        XCTAssertEqual(WeightUnit.lb.toKg(225), 102.058, accuracy: 0.001)
        XCTAssertEqual(WeightUnit.kg.display(100), 100)
    }

    func testBriefCarriesStrengthAndTiles() throws {
        let days = Day.range(from: today.adding(-20, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let evening = at(today, 21)
        h.sync(today: today, now: evening, input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        let d = at(today, 18)
        let log = StrengthLog(sessions: [StrengthSession(start: d, sets: [set("bench-press", 100, 3, at: d)])])
        let b = Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male),
                       calendar: cal, asOf: evening).brief(strength: log, generatedAt: evening)
        XCTAssertNotNil(b.strength)
        let top = DashboardTile.makeStrength(.topLift, brief: b, now: evening, calendar: cal, unit: .kg)
        XCTAssertEqual(top.value, "110")
        XCTAssertTrue(DashboardTile.makeStrength(.muscles, brief: b, now: evening, calendar: cal, unit: .kg).available)
        XCTAssertFalse(DashboardTile.makeStrength(.topLift, brief: b, now: at(today.adding(1, calendar: cal), 1), calendar: cal,
                                                  unit: .kg).available)
        let lb = DashboardTile.makeStrength(.topLift, brief: b, now: evening, calendar: cal, unit: .lb)
        XCTAssertEqual(lb.value, "243")
    }

    func testStrengthLogRoundTrip() throws {
        let d = at(today, 18)
        let log = StrengthLog(sessions: [StrengthSession(start: d, end: d.addingTimeInterval(60), sets: [set("dip", 10, 8, at: d, rpe: 8)],
                                                         savedToHealth: true)],
                              customExercises: [Exercise("custom-x", "X", .other, [.abs])])
        XCTAssertEqual(try JSONDecoder().decode(StrengthLog.self, from: JSONEncoder().encode(log)), log)
        let s = try JSONDecoder().decode(LifestyleSettings.self, from: Data(#"{"pinnedLiftID":null}"#.utf8))
        XCTAssertNil(s.pinnedLiftID, "an explicit null unpins")
        XCTAssertEqual(try JSONDecoder().decode(LifestyleSettings.self, from: Data("{}".utf8)).pinnedLiftID, "bench-press")
    }
}
