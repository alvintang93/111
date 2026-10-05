import XCTest
@testable import MarginCore

/// Health metric reports: reconciliation with the recovery engine, data
/// states, trends, history, provenance and day assignment.
final class HealthMetricsTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }
    var noon: Date { at(today, 12) }

    func harness(days n: Int, endingDaysAgo gap: Int = 0, seed: UInt64 = 9) -> PipelineHarness {
        let last = today.adding(-gap, calendar: cal)
        let days = Day.range(from: last.adding(-(n - 1), calendar: cal), to: last, calendar: cal)
        var h = PipelineHarness()
        h.sync(today: today, now: noon, input: RawFixture.input(days: days, spec: RawFixture.noisySpec(seed: seed)))
        return h
    }

    func engine(_ h: PipelineHarness, status: [StatusPeriod] = []) -> Engine {
        Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male), calendar: cal,
               asOf: noon, statusPeriods: status)
    }

    func report(_ k: HealthMetricKind, _ b: DailyBrief) -> MetricReport { b.healthMetrics!.first { $0.kind == k }! }

    func sample(_ dayOffset: Int, _ hour: Int, _ v: Double, source: String? = "Watch") -> TimedValue {
        let t = at(today.adding(dayOffset, calendar: cal), hour)
        return TimedValue(start: t, end: t, value: v, source: source)
    }

    // MARK: Reconciliation

    func testScoreInputsReconcileWithTheRecoveryComponents() throws {
        let b = engine(harness(days: 90)).brief(generatedAt: noon)
        let pairs: [(HealthMetricKind, ComponentKind)] = [(.hrv, .hrv), (.sleepingHR, .restingHR),
                                                          (.respiratoryRate, .respiratoryRate), (.wristTemperature, .wristTemperature)]
        for (m, c) in pairs {
            let r = report(m, b)
            let comp = try XCTUnwrap(b.recovery.components.first { $0.kind == c }, "\(c)")
            XCTAssertEqual(r.state, .available, "\(m)")
            XCTAssertEqual(r.current!.value, comp.value, accuracy: 1e-9, "\(m) value")
            XCTAssertEqual(r.baseline!.center, comp.baseline!, accuracy: 1e-9, "\(m) baseline")
            XCTAssertEqual(r.z!, comp.rawZ!, accuracy: 1e-9, "\(m) z")
            XCTAssertEqual(r.current!.day, today)
        }
        let hrv = report(.hrv, b)
        XCTAssertEqual(hrv.current!.count, 3)
        XCTAssertEqual(hrv.readings.filter { $0.note?.hasPrefix("Used") == true }.count, 3)
        XCTAssertEqual(hrv.deltaPercent!, (hrv.current!.value / hrv.baseline!.center - 1) * 100, accuracy: 1e-9)
    }

    func testNewMetricsNeverChangeTheScore() {
        let h = harness(days: 90)
        var input = BiomarkerInput()
        input[.spo2] = (0..<40).map { sample(-$0, 3, 96) }
        input[.vo2Max] = [sample(-10, 9, 45)]
        let plain = engine(h).brief(generatedAt: noon)
        let rich = engine(h).brief(biomarkers: input, generatedAt: noon)
        XCTAssertEqual(plain.recovery, rich.recovery)
        XCTAssertEqual(plain.plan, rich.plan)
        XCTAssertEqual(plain.strain, rich.strain)
    }

    // MARK: Data states

    func testMissingDataIsAStateNeverZero() {
        let b = engine(harness(days: 30)).brief(generatedAt: noon)
        for k: HealthMetricKind in [.spo2, .vo2Max, .bodyMass, .bodyFat, .leanMass] {
            let r = report(k, b)
            XCTAssertEqual(r.state, .noMeasurement, "\(k)")
            XCTAssertNil(r.current, "\(k)")
            XCTAssertTrue(r.history.isEmpty, "\(k)")
            XCTAssertTrue(r.trends.allSatisfy { !$0.sufficient && $0.slopePerWeek == nil }, "\(k)")
        }
        XCTAssertTrue(report(.spo2, b).stateDetail.contains("not a result"))
        XCTAssertTrue(report(.vo2Max, b).notes.contains { $0.contains("doesn't estimate") })
    }

    func testNotAuthorizedAndFailedReadsAreDistinct() {
        let empty = PipelineHarness()
        let none = Engine(records: [], today: today, settings: UserSettings(), calendar: cal, asOf: noon)
        let b = none.brief(access: HealthAccess(authorized: false), generatedAt: noon)
        XCTAssertEqual(report(.hrv, b).state, .notAuthorized)
        XCTAssertTrue(empty.records.isEmpty)

        var input = BiomarkerInput(failed: ["spo2"])
        input[.vo2Max] = [sample(-3, 9, 44)]
        let h = harness(days: 20)
        let f = engine(h).brief(biomarkers: input, access: HealthAccess(lastSyncFailed: true), generatedAt: noon)
        XCTAssertEqual(report(.spo2, f).state, .readFailed)
        XCTAssertTrue(report(.spo2, f).stateDetail.contains("nothing is saved"))
        XCTAssertEqual(report(.hrv, f).state, .readFailed, "cached HRV shown, flagged as from before the failed sync")
        XCTAssertNotNil(report(.hrv, f).current)
        XCTAssertEqual(report(.vo2Max, f).state, .available)
    }

    func testStaleAndInsufficientHistory() {
        let stale = engine(harness(days: 40, endingDaysAgo: 5)).brief(generatedAt: noon)
        XCTAssertEqual(report(.hrv, stale).state, .stale)
        XCTAssertEqual(report(.hrv, stale).current?.day, today.adding(-5, calendar: cal))

        let short = engine(harness(days: 6)).brief(generatedAt: noon)
        let hrv = report(.hrv, short)
        XCTAssertEqual(hrv.state, .insufficientHistory)
        XCTAssertNotNil(hrv.current)
        XCTAssertNil(hrv.baseline)
        XCTAssertTrue(hrv.stateDetail.contains("5 of 14"))
    }

    // MARK: Trends and changes

    func testTrendSufficiencyAndSlope() {
        let obs = (0..<30).map { k in
            MetricObservation(date: at(today.adding(k - 29, calendar: cal), 7), day: today.adding(k - 29, calendar: cal), value: 50 + Double(k))
        }
        let t = MetricMath.trends(obs, windows: [7, 30, 60], asOf: noon, sporadic: false)
        XCTAssertTrue(t[0].sufficient)
        XCTAssertEqual(t[0].slopePerWeek!, 7, accuracy: 1e-9)
        XCTAssertEqual(t[1].slopePerWeek!, 7, accuracy: 1e-9)
        XCTAssertEqual(t[1].n, 30)
        XCTAssertTrue(t[2].sufficient, "30 points satisfy the 60-day minimum of 15")
        let few = MetricMath.trends(Array(obs.suffix(3)), windows: [7], asOf: noon, sporadic: false)
        XCTAssertFalse(few[0].sufficient)
        XCTAssertNil(few[0].slopePerWeek)
        XCTAssertNil(few[0].change)
    }

    func testWeightChangesOverSevenThirtyAndNinetyDays() throws {
        var input = BiomarkerInput()
        input[.bodyMass] = [sample(-95, 7, 84), sample(-60, 7, 83), sample(-31, 7, 82), sample(-20, 7, 81.5),
                            sample(-8, 7, 81), sample(-4, 7, 80.6), sample(-1, 7, 80.4), sample(0, 7, 80.2)]
        let b = engine(harness(days: 20)).brief(biomarkers: input, generatedAt: noon)
        let w = report(.bodyMass, b)
        XCTAssertEqual(w.state, .available)
        XCTAssertEqual(w.current!.value, 80.2)
        XCTAssertEqual(w.current!.source, "Watch")
        XCTAssertEqual(w.previous!.value, 80.4)
        let byDays = Dictionary(uniqueKeysWithValues: w.trends.map { ($0.days, $0) })
        XCTAssertEqual(byDays[7]!.change!, 80.2 - 81, accuracy: 1e-9)
        XCTAssertEqual(byDays[30]!.change!, 80.2 - 82, accuracy: 1e-9)
        XCTAssertEqual(byDays[90]!.change!, 80.2 - 84, accuracy: 1e-9)
        XCTAssertNil(w.baseline, "sporadic metrics compare readings, not a rolling baseline")
    }

    func testVO2MaxUsesAppleReadingsOnly() throws {
        var input = BiomarkerInput()
        input[.vo2Max] = [sample(-80, 9, 42), sample(-40, 9, 43), sample(-5, 9, 44.5), sample(-2, 9, 120)]
        let r = report(.vo2Max, engine(harness(days: 20)).brief(biomarkers: input, generatedAt: noon))
        XCTAssertEqual(r.current!.value, 44.5, "the impossible 120 is rejected, not clamped")
        XCTAssertEqual(r.current!.value - r.previous!.value, 1.5, accuracy: 1e-9)
        XCTAssertTrue(r.notes.contains { $0.contains("1 implausible") })
        XCTAssertTrue(r.trends.first { $0.days == 90 }!.sufficient)
        XCTAssertFalse(r.trends.first { $0.days == 30 }!.sufficient, "only one valid reading in 30 days")
    }

    func testSpO2DailyMediansOvernightTagsAndBaseline() throws {
        let h = harness(days: 40)
        var input = BiomarkerInput()
        for k in 0..<30 {
            // Fixture sleep runs 23:00 -> ~06:30; 02:00 and 04:00 are overnight, 15:00 is daytime.
            input[.spo2] += [sample(-k, 2, 95), sample(-k, 4, 97), sample(-k, 15, 99)]
        }
        let r = report(.spo2, engine(h).brief(biomarkers: input, generatedAt: noon))
        // Today's 15:00 reading is after `asOf` (noon), so it is rejected as future-dated.
        XCTAssertEqual(r.history.last!.value, 96, "median of today's 95 and 97")
        XCTAssertEqual(r.history.last!.count, 2)
        XCTAssertEqual(r.history[r.history.count - 2].value, 97, "yesterday: median of 95, 97, 99")
        XCTAssertEqual(r.readings.map(\.note), ["Overnight", "Overnight"])
        XCTAssertEqual(r.baseline!.center, 97)
        XCTAssertEqual(r.state, .available)
        XCTAssertTrue(r.notes.contains { $0.contains("not a recovery input") })
    }

    func testMarkedDaysAreNotedInHistory() {
        let h = harness(days: 60)
        let p = StatusPeriod(kind: .unwell, start: today.adding(-10, calendar: cal), end: today.adding(-8, calendar: cal))
        let r = report(.hrv, engine(h, status: [p]).brief(generatedAt: noon))
        XCTAssertEqual(r.history.filter { $0.note?.contains("Marked") == true }.count, 3)
        XCTAssertEqual(r.baseline!.count, 56, "59 prior days minus 3 marked")
    }

    // MARK: Day assignment

    func testObservationsUseStoredDayWindowsAcrossTimeZones() {
        // A day built in Tokyo keeps its windows after travel back to New York.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let day = today.adding(-1, calendar: cal)
        let windows = DayWindows.nominal(for: day, calendar: tokyo)
        let record = DayRecordBuilder.build(day: day, windows: windows, input: RawDayInput(), asOf: noon, builtAt: noon)
        let e = Engine(records: [record], today: today, settings: UserSettings(), calendar: cal, asOf: noon)
        // 23:30 New York on `day - 1` is 12:30 Tokyo on `day`: inside the stored Tokyo window.
        let t = windows.activity.start.addingTimeInterval(12.5 * 3600)
        XCTAssertEqual(e.dayFor(t), day)
        XCTAssertNotEqual(Day(t, calendar: cal), day)
    }
}
