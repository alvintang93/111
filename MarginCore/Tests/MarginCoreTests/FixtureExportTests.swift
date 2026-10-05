import XCTest
@testable import MarginCore

/// Writes a synthetic payload for simulator screenshots when MARGIN_FIXTURE_OUT
/// is set. Test data only: it never ships in the app.
final class FixtureExportTests: XCTestCase {
    func testExportSimulatorPayload() throws {
        guard let out = ProcessInfo.processInfo.environment["MARGIN_FIXTURE_OUT"] else { throw XCTSkip("set MARGIN_FIXTURE_OUT") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let now = Date()
        let today = Day(now, calendar: cal)
        let days = Day.range(from: today.adding(-89, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness(calendar: cal)
        var input = RawFixture.input(days: days, calendar: cal, spec: RawFixture.noisySpec(seed: 21))
        input.workouts = input.workouts.map { WorkoutSample(start: $0.start, end: $0.end, activityType: 37, healthID: UUID(), source: "Apple Watch") }
        h.sync(today: today, now: now, input: input)
        var bio = BiomarkerInput(fetchedAt: now)
        func s(_ d: Int, _ hr: Int, _ v: Double, _ src: String) -> TimedValue {
            let t = today.adding(-d, calendar: cal).date(hour: hr, calendar: cal)
            return TimedValue(start: t, end: t, value: v, source: src)
        }
        bio[.bodyMass] = stride(from: 88, through: 0, by: -4).map { s($0, 7, 82 - 0.03 * Double(88 - $0), "Withings") }
        bio[.vo2Max] = stride(from: 85, through: 1, by: -12).map { s($0, 9, 44 + 0.02 * Double(85 - $0), "Apple Watch") }
        bio[.spo2] = (1..<40).flatMap { [s($0, 2, 96, "Apple Watch"), s($0, 4, 97, "Apple Watch")] }
        let routine = Routine(name: "Push A", items: [.exercise("bench-press", sets: 3, reps: 5), .exercise("overhead-press", sets: 3, reps: 8)],
                              createdAt: now.addingTimeInterval(-86400 * 10))
        let st = today.adding(-2, calendar: cal).date(hour: 18, calendar: cal)
        let session = StrengthSession(start: st, end: st.addingTimeInterval(3000), sets: (0..<3).map {
            StrengthSet(exerciseID: "bench-press", date: st.addingTimeInterval(Double($0) * 180), weightKg: 80, reps: 5)
        }, routineID: routine.id, routineName: routine.name)
        let strength = StrengthLog(sessions: [session])
        let act = ActivityLog(activities: [LoggedActivity(activityType: 57, start: now.addingTimeInterval(-5 * 3600),
                                                         end: now.addingTimeInterval(-4.5 * 3600), rpe: 3, notes: "Mobility", origin: .manual)])
        let intake = [IntakeEntry(date: now.addingTimeInterval(-6 * 3600), kind: .caffeine, amount: 95, label: "Coffee")]
        let b = Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male), calendar: cal, asOf: now)
            .brief(intake: intake, biomarkers: bio, strength: strength, activityLog: act, generatedAt: now, dataSyncedAt: now)
        let p = PhonePayload(sentAt: now, brief: b, strength: strength, journal: [:], lifestyle: LifestyleSettings(),
                             routines: RoutineLibrary(routines: [routine]), activityLog: act)
        try JSONEncoder().encode(p).write(to: URL(fileURLWithPath: out))
    }
}
