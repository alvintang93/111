import Foundation

/// Biomarkers, cardio focus and the compare-two-metrics series.
extension Engine {
    func biomarkerSummary(_ input: BiomarkerInput?, lifestyle: LifestyleSettings, now: Date) -> BiomarkerSummary {
        let i = todayIndex
        let input = input ?? BiomarkerInput()
        let rhr: [TimedValue] = days.compactMap { d in
            guard let v = records[d]?.appleRestingHR else { return nil }
            let t = d.date(hour: 12, calendar: calendar)
            return TimedValue(start: t, end: t, value: v)
        }
        func clean(_ k: BiomarkerKind) -> [TimedValue] { input.clean(k, asOf: now).samples }
        let vo2 = TrendModel.fit(clean(.vo2Max), asOf: now, windowDays: 365)
        let bodyMass = TrendModel.fit(clean(.bodyMass), asOf: now)
        let massKg = lifestyle.bodyMassKg ?? bodyMass?.latest

        // Biological age needs an age; VO2 max older than a year is not used.
        var bioAge: BiologicalAgeEstimate?
        if let age = settings.age, age >= 18 {
            let nights = (max(0, i - 13)...i).compactMap { records[days[$0]]?.sleep?.asleep }
            let recentRHR = days.suffix(30).compactMap { records[$0]?.appleRestingHR }
            bioAge = BiologicalAgeModel.estimate(
                age: age, sex: settings.sex, vo2Max: vo2?.latest,
                restingHR: recentRHR.count >= 7 ? Stats.median(recentRHR) : nil,
                averageSleepHours: nights.count >= 7 ? Stats.mean(nights).map { $0 / 3600 } : nil)
        }

        var hrvDev = hrvDeviations()
        var temps: [Day: Double] = [:]
        for d in days { if let t = records[d]?.wristTemperature { temps[d] = t } }
        // Cycle phases attribute each night to the day it ends, like everything else.
        hrvDev = hrvDev.filter { !excluded.contains($0.key) }
        let cycle = CycleModel.summarize(flow: input.flow, today: today, calendar: calendar, hrvDeviation: hrvDev,
                                         temperature: temps)

        return BiomarkerSummary(
            bodyMass: bodyMass,
            bodyFat: TrendModel.fit(clean(.bodyFat), asOf: now),
            leanMass: TrendModel.fit(clean(.leanMass), asOf: now),
            vo2Max: vo2,
            restingHR: TrendModel.fit(rhr, asOf: now),
            bloodPressure: BloodPressureSummary.make(systolic: clean(.systolic), diastolic: clean(.diastolic), asOf: now),
            glucose: GlucoseSummary.make(clean(.glucose), asOf: now, calendar: calendar),
            nutrition: NutritionSummary.make(input.nutrition, today: today, bodyMassKg: massKg, calendar: calendar),
            biologicalAge: bioAge,
            cycle: cycle,
            running: RunningSummary.make(input.runs, asOf: now),
            fetchedAt: input.fetchedAt)
    }

    func cardioFocusSummary(zones: ZoneSettings) -> CardioFocusSummary {
        let bounds = zones.bpmBounds(hrRest: hrRest, hrMax: hrMax)
        var groups = Array(repeating: 0.0, count: CardioFocus.allCases.count)
        var workouts: [WorkoutFocus] = []
        for d in days.suffix(28) {
            for w in records[d]?.workoutDetails ?? [] {
                let z = ZoneModel.zoneSeconds(bpmSeconds: w.hrSeconds, bounds: bounds)
                groups[0] += (z[1] + z[2]) / 60
                groups[1] += (z[3] + z[4]) / 60
                groups[2] += z[5] / 60
                workouts.append(WorkoutFocus(start: w.start, activityType: w.activityType, minutes: w.minutes,
                                             zoneMinutes: z.map { $0 / 60 }, focus: CardioFocus.classify(zoneSeconds: z)))
            }
        }
        return CardioFocusSummary(minutes28d: groups, workouts: Array(workouts.suffix(10)), bounds: bounds)
    }

    /// Last `days` days of each comparable metric, oldest first; days without a value are skipped.
    func compareSeries(intake: [IntakeEntry], lookback: Int = 30) -> [MetricSeries] {
        let range = Array(days.indices.suffix(lookback))
        func series(_ m: CompareMetric, _ f: (Int) -> Double?) -> MetricSeries {
            MetricSeries(metric: m, points: range.compactMap { k in f(k).map { DayValue(day: days[k], value: $0) } })
        }
        func intakeTotal(_ kind: IntakeKind, _ k: Int) -> Double? {
            let w = activityWindow(at: k)
            let xs = intake.filter { $0.kind == kind && w.contains($0.date) }
            return xs.isEmpty ? nil : xs.reduce(0) { $0 + $1.amount }
        }
        return [
            series(.recovery) { k in recovery(at: k).score.map(Double.init) },
            series(.hrv) { k in records[days[k]]?.lnHRV.map(exp) },
            series(.sleepingHR) { k in records[days[k]]?.sleepingHR },
            series(.sleepHours) { k in records[days[k]]?.sleep.map { $0.asleep / 3600 } },
            series(.sleepScore) { k in sleepSummary(at: k).map { Double($0.score) } },
            series(.load) { k in
                guard let r = records[days[k]], r.coverageHours >= params.minCoverageHours else { return nil }
                return trimp(r)
            },
            series(.stress) { k in stressSummary(at: k).score.map(Double.init) },
            series(.steps) { k in records[days[k]].flatMap { $0.steps > 0 ? $0.steps : nil } },
            series(.caffeine) { k in intakeTotal(.caffeine, k) },
            series(.water) { k in intakeTotal(.water, k) },
        ]
    }
}
