import XCTest
@testable import MarginCore

/// Batch 2: trends, biological age, blood pressure, glucose, nutrition, cycle,
/// running form, custom zones, cardio focus, compare series and the smart alarm.
final class BiomarkerTests: XCTestCase {
    let today = Day(year: 2026, month: 6, day: 30)
    var cal: Calendar { testCalendar }
    var now: Date { at(today, 12) }

    func daily(_ n: Int, every: Int = 1, _ f: (Int) -> Double) -> [TimedValue] {
        stride(from: n - 1, through: 0, by: -every).map { k in
            let t = at(today.adding(-k, calendar: cal), 8)
            return TimedValue(start: t, end: t, value: f(k))
        }
    }

    // MARK: Trends

    func testTrendRecoversALinearSlopeAndProjects() throws {
        // 80 kg falling 0.1 kg per day, a reading every 3 days.
        let xs = daily(60, every: 3) { k in 80 - 0.1 * Double(60 - k) }
        let t = try XCTUnwrap(TrendModel.fit(xs, asOf: at(today, 8)))
        XCTAssertEqual(t.slopePerWeek!, -0.7, accuracy: 1e-9)
        // The last reading is 2 days old; the projection is 30 days past `asOf`.
        XCTAssertEqual(t.projected30!, t.latest - 0.1 * 32, accuracy: 1e-9)
        XCTAssertEqual(t.projectedHigh! - t.projectedLow!, 0, accuracy: 1e-9, "no scatter, no band")
        XCTAssertEqual(t.count, 20)
    }

    func testTrendIgnoresAnOutlierAndNeedsEnoughData() throws {
        var xs = daily(30, every: 2) { _ in 20.0 }
        xs[7] = TimedValue(start: xs[7].start, end: xs[7].end, value: 35)
        XCTAssertEqual(try XCTUnwrap(TrendModel.fit(xs, asOf: now)).slopePerWeek!, 0, accuracy: 1e-9)
        XCTAssertNil(TrendModel.fit(daily(3) { _ in 1 }, asOf: now)!.slopePerWeek, "3 readings")
        XCTAssertNil(TrendModel.fit(daily(10) { _ in 1 }, asOf: now)!.slopePerWeek, "under 14 days of span")
        XCTAssertNil(TrendModel.fit([], asOf: now))
        XCTAssertLessThanOrEqual(TrendModel.fit(daily(90) { Double($0) }, asOf: now)!.points.count, 60)
    }

    // MARK: Biological age

    func testFitnessAgeAndAdjustments() {
        let typical = BiologicalAgeModel.typicalVO2Max(age: 40, sex: .male)
        XCTAssertEqual(typical, 44, accuracy: 1e-9)
        XCTAssertEqual(BiologicalAgeModel.fitnessAge(vo2Max: typical, sex: .male), 40, accuracy: 1e-9)
        XCTAssertEqual(BiologicalAgeModel.fitnessAge(vo2Max: 48, sex: .male), 30, accuracy: 1e-9)
        XCTAssertEqual(BiologicalAgeModel.restingHRYears(70, withVO2: false), 1.7, accuracy: 1e-9)
        XCTAssertEqual(BiologicalAgeModel.restingHRYears(70, withVO2: true), 0.85, accuracy: 1e-9)
        XCTAssertEqual(BiologicalAgeModel.sleepYears(hours: 8), 0)
        XCTAssertEqual(BiologicalAgeModel.sleepYears(hours: 6), 1.3, accuracy: 1e-9)
        XCTAssertEqual(BiologicalAgeModel.sleepYears(hours: 3), 3)

        let e = BiologicalAgeModel.estimate(age: 40, sex: .male, vo2Max: 48, restingHR: 50, averageSleepHours: 7.5)
        XCTAssertEqual(e.estimate, 30 - 0.85, accuracy: 1e-9)
        XCTAssertEqual(e.components.map(\.name), ["Cardio fitness", "Resting HR", "Sleep"])
        XCTAssertEqual(e.components.reduce(Double(e.chronological)) { $0 + $1.years }, e.estimate, accuracy: 1e-9)
        let noVO2 = BiologicalAgeModel.estimate(age: 40, sex: .female, vo2Max: nil, restingHR: nil, averageSleepHours: nil)
        XCTAssertEqual(noVO2.estimate, 40)
        XCTAssertEqual(BiologicalAgeModel.estimate(age: 30, sex: .male, vo2Max: 10, restingHR: 100, averageSleepHours: 4).estimate,
                       50, "clamped to 20 years above chronological age")
    }

    // MARK: Blood pressure, glucose, nutrition

    func testBloodPressureCategoriesAndPairing() throws {
        XCTAssertEqual(BloodPressureCategory(systolic: 119, diastolic: 79), .normal)
        XCTAssertEqual(BloodPressureCategory(systolic: 125, diastolic: 79), .elevated)
        XCTAssertEqual(BloodPressureCategory(systolic: 118, diastolic: 82), .high1)
        XCTAssertEqual(BloodPressureCategory(systolic: 141, diastolic: 70), .high2)
        let sys = daily(20, every: 5) { _ in 128 }
        var dia = daily(20, every: 5) { _ in 78 }
        dia.removeLast()
        let bp = try XCTUnwrap(BloodPressureSummary.make(systolic: sys, diastolic: dia, asOf: now))
        XCTAssertEqual(bp.latestDate, sys[sys.count - 2].start, "unpaired readings are skipped")
        XCTAssertEqual(bp.category, .elevated)
        XCTAssertEqual(bp.readings30d, 3)
        XCTAssertNil(BloodPressureSummary.make(systolic: sys, diastolic: [], asOf: now))
    }

    func testGlucoseTimeInRange() throws {
        let t0 = now.addingTimeInterval(-20 * 3600)
        let xs = [60.0, 100, 120, 160].enumerated().map { k, v in
            TimedValue(start: t0.addingTimeInterval(Double(k) * 3600), end: t0.addingTimeInterval(Double(k) * 3600), value: v)
        }
        let g = try XCTUnwrap(GlucoseSummary.make(xs, asOf: now, calendar: cal))
        XCTAssertEqual(g.latest, 160)
        XCTAssertEqual(g.readings24h, 4)
        XCTAssertEqual(g.inRange24h!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(g.mean24h!, 110, accuracy: 1e-12)
    }

    func testNutritionSkipsUnloggedDays() throws {
        let days = [
            NutritionDay(day: today, energyKcal: 2000, proteinG: 140),
            NutritionDay(day: today.adding(-1, calendar: cal)),
            NutritionDay(day: today.adding(-2, calendar: cal), energyKcal: 2400, proteinG: 100),
            NutritionDay(day: today.adding(-10, calendar: cal), energyKcal: 9999),
        ]
        let n = try XCTUnwrap(NutritionSummary.make(days, today: today, bodyMassKg: 80, calendar: cal))
        XCTAssertEqual(n.loggedDays7, 2)
        XCTAssertEqual(n.average7!.energyKcal!, 2200, accuracy: 1e-9)
        XCTAssertEqual(n.proteinPerKg7!, 1.5, accuracy: 1e-9)
        XCTAssertEqual(n.today?.energyKcal, 2000)
        XCTAssertNil(NutritionSummary.make([NutritionDay(day: today)], today: today, bodyMassKg: nil, calendar: cal))
    }

    // MARK: Cycle

    func flow(starts: [Day], days: Int = 5) -> [FlowDay] {
        starts.flatMap { s in (0..<days).map { FlowDay(day: s.adding($0, calendar: cal), level: 3) } }
    }

    func testCycleStartsLengthsAndPrediction() throws {
        let s1 = today.adding(-90, calendar: cal), s2 = s1.adding(29, calendar: cal)
        let s3 = s2.adding(30, calendar: cal), s4 = s3.adding(28, calendar: cal)
        var f = flow(starts: [s1, s2, s3, s4])
        f.append(FlowDay(day: s2.adding(6, calendar: cal), level: 2))   // spotting after a 1-day gap: same period
        XCTAssertEqual(CycleModel.starts(f, calendar: cal), [s1, s2, s3, s4])
        let c = try XCTUnwrap(CycleModel.summarize(flow: f, today: today, calendar: cal, hrvDeviation: [:], temperature: [:]))
        XCTAssertEqual(c.medianLength, 29)
        XCTAssertEqual(c.cyclesUsed, 3)
        XCTAssertEqual(c.lastStart, s4)
        XCTAssertEqual(c.cycleDay, 4)
        XCTAssertEqual(c.phase, .menstrual)
        XCTAssertEqual(c.predictedNextStart, s4.adding(29, calendar: cal))
    }

    func testCyclePhasesAndStatsByPhase() throws {
        XCTAssertEqual(CycleModel.phase(cycleDay: 3, length: 28, periodDays: 5), .menstrual)
        XCTAssertEqual(CycleModel.phase(cycleDay: 8, length: 28, periodDays: 5), .follicular)
        XCTAssertEqual(CycleModel.phase(cycleDay: 14, length: 28, periodDays: 5), .ovulatory)
        XCTAssertEqual(CycleModel.phase(cycleDay: 20, length: 28, periodDays: 5), .luteal)

        // Temperature 0.3 °C higher in the luteal phase.
        let s1 = today.adding(-56, calendar: cal), s2 = s1.adding(28, calendar: cal)
        var temps: [Day: Double] = [:]
        for d in Day.range(from: s1, to: today, calendar: cal) {
            let k = CycleModel.daysBetween(d >= s2 ? s2 : s1, d, calendar: cal) + 1
            temps[d] = CycleModel.phase(cycleDay: k, length: 28, periodDays: 5) == .luteal ? 34.8 : 34.5
        }
        let c = try XCTUnwrap(CycleModel.summarize(flow: flow(starts: [s1, s2]), today: today, calendar: cal,
                                                   hrvDeviation: [:], temperature: temps))
        let luteal = c.byPhase.first { $0.phase == .luteal }!
        let follicular = c.byPhase.first { $0.phase == .follicular }!
        XCTAssertEqual(luteal.temperatureDelta! - follicular.temperatureDelta!, 0.3, accuracy: 1e-9)
        XCTAssertNil(CycleModel.summarize(flow: [], today: today, calendar: cal, hrvDeviation: [:], temperature: [:]))
    }

    // MARK: Running

    func testRunningTypicalUsesOtherRuns() throws {
        func run(_ k: Int, cadence: Double, stride: Double) -> RunMetrics {
            let s = at(today.adding(-k, calendar: cal), 7)
            return RunMetrics(start: s, end: s.addingTimeInterval(1800), distanceKm: 6, steps: cadence * 30, strideLengthM: stride)
        }
        let r = try XCTUnwrap(RunningSummary.make([run(9, cadence: 160, stride: 1.1), run(5, cadence: 170, stride: 1.2),
                                                   run(1, cadence: 180, stride: 1.3)], asOf: now))
        XCTAssertEqual(r.latest.cadence!, 180, accuracy: 1e-9)
        XCTAssertEqual(r.typical!.cadence!, 165, accuracy: 1e-9)
        XCTAssertEqual(r.typical!.strideLengthM!, 1.15, accuracy: 1e-9)
        XCTAssertEqual(r.latest.pace!, 5, accuracy: 1e-9)
        XCTAssertEqual(RunMetrics(start: now, end: now.addingTimeInterval(600), speedMS: 1000.0 / 300).pace!, 5, accuracy: 1e-9)
        XCTAssertNil(RunningSummary.make([run(1, cadence: 170, stride: 1)], asOf: now)!.typical)
    }

    // MARK: Zones and cardio focus

    func testZoneBoundsPerMode() {
        XCTAssertEqual(ZoneSettings.standard.bpmBounds(hrRest: 50, hrMax: 190), [120, 134, 148, 162, 176])
        XCTAssertEqual(ZoneSettings.defaults(for: .maxHR).bpmBounds(hrRest: 50, hrMax: 200), [100, 120, 140, 160, 180])
        XCTAssertEqual(ZoneSettings.defaults(for: .bpm).bpmBounds(hrRest: 50, hrMax: 200), [110, 130, 145, 160, 175])
        let broken = ZoneSettings(mode: .bpm, lowerBounds: [150, 140, 160, 170, 180])
        XCTAssertFalse(broken.isValid)
        XCTAssertEqual(broken.bpmBounds(hrRest: 50, hrMax: 190), ZoneSettings.standard.bpmBounds(hrRest: 50, hrMax: 190))
    }

    func testDefaultZonesMatchTheOriginalZoneSplit() {
        let h = HeartRateHistogram(secondsByBPM: [60: 100, 121: 200, 135: 300, 150: 400, 163: 500, 180: 600])
        let original = h.zoneSeconds(hrRest: 50, hrMax: 190)
        let custom = ZoneModel.zoneSeconds(histogram: h, bounds: ZoneSettings.standard.bpmBounds(hrRest: 50, hrMax: 190))
        XCTAssertEqual(custom, original)
    }

    func testCardioFocusRules() {
        XCTAssertNil(CardioFocus.classify(zoneSeconds: [3600, 100, 100, 0, 0, 0]), "under 5 minutes in zones")
        XCTAssertEqual(CardioFocus.classify(zoneSeconds: [0, 1800, 1200, 600, 0, 0]), .lowAerobic)
        XCTAssertEqual(CardioFocus.classify(zoneSeconds: [0, 600, 600, 900, 300, 0]), .highAerobic)
        XCTAssertEqual(CardioFocus.classify(zoneSeconds: [0, 600, 600, 600, 0, 240]), .anaerobic)
        XCTAssertEqual(CardioFocus.classify(zoneSeconds: [0, 6000, 0, 0, 0, 200]), .lowAerobic, "3 min but under 10%")
    }

    // MARK: Compare

    func testSpearmanAndLaggedPairs() throws {
        XCTAssertEqual(Correlation.spearman([1, 2, 3, 4, 5], [2, 4, 8, 16, 32])!.rho, 1, accuracy: 1e-12)
        XCTAssertEqual(Correlation.spearman([1, 2, 3, 4, 5], [5, 4, 3, 2, 1])!.rho, -1, accuracy: 1e-12)
        XCTAssertEqual(Correlation.ranks([10, 20, 20, 30]), [1, 2.5, 2.5, 4])
        XCTAssertNil(Correlation.spearman([1, 1, 1], [1, 2, 3]))
        let r = try XCTUnwrap(Correlation.spearman([1, 2, 3, 4, 5, 6, 7, 8], [2, 1, 4, 3, 6, 5, 8, 7]))
        XCTAssertLessThan(r.pValue!, 0.05)

        let a = MetricSeries(metric: .caffeine, points: (0..<5).map { DayValue(day: today.adding(-$0, calendar: cal), value: Double($0)) })
        let b = MetricSeries(metric: .hrv, points: (0..<5).map { DayValue(day: today.adding(-$0, calendar: cal), value: 10 * Double($0)) })
        let same = Correlation.pairs(a, b, lagDays: 0, calendar: cal)
        XCTAssertEqual(same.count, 5)
        let next = Correlation.pairs(a, b, lagDays: 1, calendar: cal)
        XCTAssertEqual(next.count, 4, "today's caffeine has no tomorrow yet")
        XCTAssertTrue(next.allSatisfy { $0.y == 10 * ($0.x - 1) })
    }

    // MARK: Smart alarm

    func testSmartAlarmWakesOnSustainedMovement() {
        var d = SmartAlarmDetector()
        let still = Array(repeating: 1.002, count: 300)
        let moving = Array(repeating: 1.05, count: 300)
        XCTAssertFalse(d.add(epoch: still))
        XCTAssertFalse(d.add(epoch: moving))
        XCTAssertFalse(d.add(epoch: still), "a single twitch is not enough")
        XCTAssertFalse(d.add(epoch: moving))
        XCTAssertTrue(d.add(epoch: moving))
        XCTAssertFalse(d.add(epoch: []))
        XCTAssertEqual(d.consecutive, 0)
    }

    func testSmartAlarmNextWindow() {
        var s = SmartAlarmSettings()
        s.wakeMinutes = 6 * 60 + 30
        s.windowMinutes = 20
        let evening = at(today, 22)
        let w = s.nextWindow(after: evening, calendar: cal)
        XCTAssertEqual(w.wake, at(today.adding(1, calendar: cal), 6, 30))
        XCTAssertEqual(w.start, at(today.adding(1, calendar: cal), 6, 10))
        let early = s.nextWindow(after: at(today, 3), calendar: cal)
        XCTAssertEqual(early.wake, at(today, 6, 30))
        s.windowMinutes = 90
        XCTAssertEqual(s.nextWindow(after: evening, calendar: cal).start, at(today.adding(1, calendar: cal), 6), "window capped at 30 min")
    }

    // MARK: Engine

    func testBriefCarriesBiomarkersFocusAndSeries() throws {
        let days = Day.range(from: today.adding(-89, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let evening = at(today, 21)
        h.sync(today: today, now: evening, input: RawFixture.input(days: days, spec: RawFixture.noisySpec(seed: 7)))
        var input = BiomarkerInput(fetchedAt: evening)
        input[.vo2Max] = daily(120, every: 20) { _ in 44 }
        input[.bodyMass] = daily(60, every: 4) { k in 80 - 0.05 * Double(60 - k) }
        input.flow = flow(starts: [today.adding(-40, calendar: cal), today.adding(-12, calendar: cal)])
        let settings = UserSettings(age: 40, sex: .male)
        let b = Engine(records: Array(h.records.values), today: today, settings: settings, calendar: cal, asOf: evening)
            .brief(biomarkers: input, generatedAt: evening)
        let bio = try XCTUnwrap(b.biomarkers)
        XCTAssertEqual(bio.vo2Max?.latest, 44)
        XCTAssertNotNil(bio.bodyMass?.slopePerWeek)
        XCTAssertEqual(bio.biologicalAge?.components.first?.years ?? 99, 0, accuracy: 1e-9, "typical VO2 max for 40")
        XCTAssertEqual(bio.cycle?.cycleDay, 13)
        XCTAssertNotNil(bio.restingHR)

        let focus = try XCTUnwrap(b.cardioFocus)
        // Fixture workouts hold 145 bpm: 70% of heart-rate reserve for a 35-55-183 profile is zone 3.
        XCTAssertEqual(focus.workouts.last?.focus, .highAerobic)
        XCTAssertGreaterThan(focus.minutes28d[1], 0)

        let series = try XCTUnwrap(b.series)
        XCTAssertEqual(series.map(\.metric), CompareMetric.allCases)
        XCTAssertEqual(series.first { $0.metric == .hrv }?.points.count, 30)
        XCTAssertTrue(series.first { $0.metric == .caffeine }!.points.isEmpty)
    }

    func testCustomZonesChangeTodayZoneMinutes() {
        let days = Day.range(from: today.adding(-30, calendar: cal), to: today, calendar: cal)
        var h = PipelineHarness()
        let evening = at(today, 21)
        h.sync(today: today, now: evening, input: RawFixture.input(days: days, spec: { _ in NightSpec() }))
        let e = Engine(records: Array(h.records.values), today: today, settings: UserSettings(age: 35, sex: .male),
                       calendar: cal, asOf: evening)
        var lifestyle = LifestyleSettings()
        let standard = e.brief(lifestyle: lifestyle, generatedAt: evening).load.todayZoneMinutes
        lifestyle.zones = ZoneSettings(mode: .bpm, lowerBounds: [100, 110, 120, 130, 140])
        let custom = e.brief(lifestyle: lifestyle, generatedAt: evening).load.todayZoneMinutes
        XCTAssertEqual(standard.reduce(0, +), custom.reduce(0, +), accuracy: 1e-9)
        XCTAssertGreaterThan(custom[5], 40, "the 145 bpm workout is zone 5 with these bounds")
        XCTAssertEqual(standard[5], 0)
    }

    func testOlderLifestyleSettingsGetDefaultZonesAndAlarm() throws {
        let s = try JSONDecoder().decode(LifestyleSettings.self, from: Data(#"{"typicalDoseMg":80}"#.utf8))
        XCTAssertEqual(s.zones, .standard)
        XCTAssertFalse(s.smartAlarm.enabled)
        XCTAssertEqual(s.typicalDoseMg, 80)
    }
}
