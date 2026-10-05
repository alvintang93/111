import XCTest
@testable import MarginCore

/// Provenance, HRV reconciliation and biomarker sample hygiene.
final class IntegrityTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }

    func build(_ input: RawDayInput, asOf: Date? = nil) -> DayRecord {
        DayRecordBuilder.build(day: today, windows: .nominal(for: today, calendar: cal), input: input,
                               asOf: asOf ?? at(today, 23), builtAt: nil)
    }

    func testDisplayedHRVReconcilesWithTheScoreInput() {
        var input = RawFixture.input(days: [today], spec: { _ in NightSpec() })
        // A daytime Breathe reading must be kept for display but not enter the score.
        input.hrv.append(TimedValue(start: at(today, 14), end: at(today, 14, 1), value: 90, source: "Watch"))
        let r = build(input)
        let used = r.hrvReadings.filter(\.usedByScore)
        XCTAssertEqual(used.count, r.hrvSampleCount)
        XCTAssertEqual(Stats.mean(used.map { log($0.sdnnMs) })!, r.lnHRV!, accuracy: 1e-12)
        let daytime = r.hrvReadings.filter { !$0.usedByScore }
        XCTAssertEqual(daytime.map(\.sdnnMs), [90])
        XCTAssertEqual(daytime.first?.source, "Watch")
        XCTAssertEqual(r.hrvReadings.map(\.date), r.hrvReadings.map(\.date).sorted())
    }

    func testSourcesNeverChangeScoresOrFingerprints() {
        let plain = RawFixture.input(days: [today], spec: { _ in NightSpec() })
        var tagged = plain
        tagged.hrv = plain.hrv.map { TimedValue(start: $0.start, end: $0.end, value: $0.value, source: "A") }
        tagged.respiratoryRate = plain.respiratoryRate.map { TimedValue(start: $0.start, end: $0.end, value: $0.value, source: "B") }
        let a = build(plain), b = build(tagged)
        XCTAssertEqual(a.lnHRV, b.lnHRV)
        XCTAssertEqual(a.respiratoryRate, b.respiratoryRate)
        XCTAssertEqual(a.sourceFingerprint, b.sourceFingerprint)
        XCTAssertEqual(b.respiratorySampleCount, 2)
    }

    func testExactDuplicatesFromTwoSourcesCountOnce() {
        var input = RawFixture.input(days: [today], spec: { _ in NightSpec() })
        input.hrv += input.hrv.map { TimedValue(start: $0.start, end: $0.end, value: $0.value, source: "Copy") }
        let r = build(input)
        XCTAssertEqual(r.hrvSampleCount, 3)
        XCTAssertEqual(r.ingestion[.hrv].duplicates, 3)
    }

    func testWorkoutIdentityIsCarriedThrough() {
        var input = RawFixture.input(days: [today], spec: { _ in NightSpec() })
        let id = UUID()
        let w = input.workouts[0]
        input.workouts = [WorkoutSample(start: w.start, end: w.end, activityType: w.activityType, healthID: id, source: "Workout")]
        let d = build(input).workoutDetails
        XCTAssertEqual(d.first?.healthID, id)
        XCTAssertEqual(d.first?.source, "Workout")
    }

    func testOldCacheSchemaIsRebuiltNotMisread() throws {
        let old = Data(#"{"schema":4,"records":[]}"#.utf8)
        XCTAssertEqual(RecordCacheFile.decode(old), .schemaMismatch(found: 4, expected: 5))
    }

    // MARK: Biomarker hygiene

    func sample(_ dayOffset: Int, _ v: Double, source: String? = nil) -> TimedValue {
        let t = at(today.adding(dayOffset, calendar: cal), 8)
        return TimedValue(start: t, end: t, value: v, source: source)
    }

    func testBiomarkersRejectImplausibleDuplicateAndFutureSamples() {
        var input = BiomarkerInput()
        input[.bodyMass] = [sample(-3, 80), sample(-3, 80), sample(-2, 0), sample(-1, 800), sample(-1, 79.5), sample(5, 79)]
        let (clean, stats) = input.clean(.bodyMass, asOf: at(today, 12))
        XCTAssertEqual(clean.map(\.value), [80, 79.5], "no clamping: 0 and 800 kg are rejected")
        XCTAssertEqual(stats.duplicates, 1)
        XCTAssertEqual(stats.implausible, 2)
        XCTAssertEqual(stats.future, 1)
        XCTAssertEqual(stats.received, 6)
    }

    func testOxygenSaturationUnitsAndRange() {
        XCTAssertEqual(HealthUnits.percent(fromFraction: 0.97)!, 97, accuracy: 1e-9)
        XCTAssertNil(HealthUnits.percent(fromFraction: 97), "a percent value where a fraction belongs is rejected, not rescaled")
        XCTAssertNil(HealthUnits.percent(fromFraction: -0.1))
        XCTAssertNil(HealthUnits.percent(fromFraction: .nan))
        var input = BiomarkerInput()
        input[.spo2] = [sample(-1, 49.9), sample(-1, 50), sample(0, 100)]
        XCTAssertEqual(input.clean(.spo2, asOf: at(today, 12)).samples.map(\.value), [50, 100])
    }

    func testFailedReadsAreRecordedSeparatelyFromNoData() {
        let input = BiomarkerInput(failed: ["spo2"])
        XCTAssertTrue(input.didFail(.spo2))
        XCTAssertFalse(input.didFail(.vo2Max))
        XCTAssertTrue(input[.spo2].isEmpty)
    }

    func testSanitisedBiomarkersFeedTheBodyTrends() throws {
        let days = Day.range(from: today.adding(-20, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        h.sync(today: today, now: at(today, 12), input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        var input = BiomarkerInput()
        input[.vo2Max] = [sample(-30, 44), sample(-1, 990)]
        let b = Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 40, sex: .male),
                       calendar: cal, asOf: at(today, 12)).brief(biomarkers: input, generatedAt: at(today, 12))
        XCTAssertEqual(b.biomarkers?.vo2Max?.latest, 44, "an impossible VO2 max is never the latest value")
    }
}
