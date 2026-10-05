import Foundation

/// Daytime summaries: strain, stress, energy, heart-rate recovery, caffeine
/// and hydration, and the timeline. All derived from the same records, HRrest
/// and HRmax as the recovery score, so they stay consistent with it.
extension Engine {
    func activityWindow(at i: Int) -> DateInterval { windows(at: i).activity }

    /// Reference load for strain 50: chronic load once eligible, else a fixed provisional value.
    func strainReference() -> (Double, StrainSummary.Reference) {
        if let lp = eligibleCTL(throughIndex: loadPoints.count - 1) { return (lp.ctl, .chronicLoad) }
        return (params.strainFallbackReference, .provisional)
    }

    func strainSummary(at i: Int, plan: Plan) -> StrainSummary {
        let (ref, kind) = strainReference()
        let rec = records[days[i]]
        let load = rec.flatMap(trimp)
        let start = activityWindow(at: i).start
        let slices = rec?.hours ?? []
        var hourly = slices.map { s in
            HourValue(hour: s.hour, start: start.addingTimeInterval(Double(s.hour) * 3600),
                      value: s.trimp(hrRest: hrRest, hrMax: hrMax, sex: settings.sex, floorHRR: params.activityFloorHRR))
        }
        // Bins use 10-bpm midpoints; rescale so the hours add up to the exact daily load.
        let binTotal = hourly.reduce(0) { $0 + $1.value }
        if let l = load, binTotal > 0 {
            for k in hourly.indices { hourly[k].value *= l / binTotal }
        }
        let hasData = (rec?.coverageHours ?? 0) > 0
        func scaled(_ x: Double?) -> Int? { x.map { Int(StrainModel.score(load: $0, reference: ref).rounded()) } }
        return StrainSummary(score: hasData ? scaled(load ?? 0) : nil, load: load, referenceLoad: ref, reference: kind,
                             targetLow: scaled(plan.targetLow), targetHigh: scaled(plan.targetHigh),
                             hourly: hourly.filter { $0.value > 0 })
    }

    func stressSummary(at i: Int) -> StressSummary {
        StressModel.summarize(slices: records[days[i]]?.hours ?? [], windowStart: activityWindow(at: i).start,
                              hrRest: hrRest, hrMax: hrMax, params: params)
    }

    func energySummary(at i: Int, recovery: Recovery, sleep: SleepSummary?, strain: StrainSummary,
                       stress: StressSummary, now: Date) -> EnergySummary? {
        guard let wake = records[days[i]]?.sleep?.mainWake,
              let (start, source) = EnergyModel.startLevel(recovery: recovery.score, sleepScore: sleep?.score,
                                                           params: params) else { return nil }
        let loads = Dictionary(strain.hourly.map { ($0.hour, $0.value) }, uniquingKeysWith: { a, _ in a })
        var levels: [Int: Int] = [:]
        for h in stress.hours { if let l = h.level { levels[h.hour] = l } }
        return EnergyModel.run(start: start, source: source, wake: wake, asOf: now,
                               windowStart: activityWindow(at: i).start, slices: records[days[i]]?.hours ?? [],
                               hourlyLoad: loads, referenceLoad: strain.referenceLoad, stressLevels: levels,
                               params: params)
    }

    func heartRateRecoverySummary(at i: Int) -> HeartRateRecoverySummary? {
        let lo = max(0, i - params.heartRateRecoveryBaselineDays + 1)
        var points: [HeartRateRecoveryPoint] = []
        var latest: (Day, WorkoutDetail)?
        for d in days[lo...i] {
            for w in records[d]?.workoutDetails ?? [] {
                latest = (d, w)
                if let drop = w.recovery1 {
                    points.append(HeartRateRecoveryPoint(day: d, start: w.start, activityType: w.activityType, drop: drop))
                }
            }
        }
        guard let last = latest else { return nil }
        // Typical value excludes the newest measured workout, so it can be compared with it.
        let prior = points.dropLast().map(\.drop)
        return HeartRateRecoverySummary(latest: last.1, latestDay: last.0,
                                        typicalDrop: prior.count >= 3 ? Stats.median(prior) : nil,
                                        recent: Array(points.suffix(14)))
    }

    /// Usual sleep onset as minutes after the 18:00 night-window start (median of the last 7 nights).
    func usualOnsetMinutes(at i: Int) -> Double? {
        let mins: [Double] = (max(0, i - 6)...i).compactMap { k in
            guard let n = records[days[k]]?.sleep else { return nil }
            return n.mainOnset.timeIntervalSince(windows(at: k).night.start) / 60
        }
        return mins.count >= 3 ? Stats.median(mins) : nil
    }

    func intakeSummary(at i: Int, entries: [IntakeEntry], lifestyle: LifestyleSettings) -> IntakeSummary {
        let day = days[i]
        let act = activityWindow(at: i)
        let bedtime: Date
        let fromHistory: Bool
        if let m = usualOnsetMinutes(at: i) {
            bedtime = day.date(hour: 18, calendar: calendar).addingTimeInterval(m * 60)
            fromHistory = true
        } else {
            let m = lifestyle.defaultBedtimeMinutes
            let base = m < 12 * 60 ? day.adding(1, calendar: calendar) : day
            bedtime = base.date(calendar: calendar).addingTimeInterval(TimeInterval(m * 60))
            fromHistory = false
        }
        let now = asOf ?? act.end
        let half = lifestyle.caffeineHalfLifeHours
        let today = entries.filter { act.contains($0.date) }.sorted { $0.date < $1.date }
        let relevant = entries.filter { $0.date <= now && $0.date > now.addingTimeInterval(-48 * 3600) }
        var curve: [CaffeinePoint] = []
        var t = day.date(hour: 6, calendar: calendar)
        let curveEnd = bedtime.addingTimeInterval(3600)
        while t <= curveEnd {
            curve.append(CaffeinePoint(date: t, mg: CaffeineModel.remaining(relevant, at: t, halfLifeHours: half)))
            t = t.addingTimeInterval(1800)
        }
        let workoutMinutes = records[day]?.workouts.minutes ?? 0
        return IntakeSummary(
            caffeineTodayMg: today.filter { $0.kind == .caffeine }.reduce(0) { $0 + $1.amount },
            caffeineNowMg: CaffeineModel.remaining(relevant, at: now, halfLifeHours: half),
            caffeineAtBedtimeMg: CaffeineModel.remaining(relevant, at: bedtime, halfLifeHours: half),
            bedtime: bedtime, bedtimeFromHistory: fromHistory,
            cutoff: CaffeineModel.cutoff(existing: relevant, bedtime: bedtime, dose: lifestyle.typicalDoseMg,
                                         limit: lifestyle.bedtimeCaffeineLimitMg, halfLifeHours: half),
            limitMg: lifestyle.bedtimeCaffeineLimitMg,
            waterTodayMl: today.filter { $0.kind == .water }.reduce(0) { $0 + $1.amount },
            waterTargetMl: CaffeineModel.waterTarget(bodyMassKg: lifestyle.bodyMassKg, mlPerKg: lifestyle.waterMlPerKg,
                                                     workoutMinutes: workoutMinutes),
            curve: curve, entriesToday: today)
    }

    func timeline(at i: Int, journal: [Day: Set<String>], entries: [IntakeEntry]) -> DayTimeline {
        let day = days[i]
        let act = activityWindow(at: i)
        var items: [TimelineItem] = []
        func hm(_ seconds: TimeInterval) -> String {
            let m = Int((seconds / 60).rounded())
            return "\(m / 60)h \(String(format: "%02d", m % 60))m"
        }
        if let n = records[day]?.sleep {
            items.append(TimelineItem(date: n.mainOnset, kind: .sleep, title: "Asleep",
                                      detail: "\(hm(n.asleep)) · deep \(hm(n.deep)) · REM \(hm(n.rem)) · core \(hm(n.core + n.unspecified))"))
            items.append(TimelineItem(date: n.mainWake, kind: .wake, title: "Woke",
                                      detail: n.efficiency.map { String(format: "Efficiency %.0f%%", $0 * 100) } ?? ""))
        }
        for w in records[day]?.workoutDetails ?? [] {
            var parts = [String(format: "%.0f min", w.minutes)]
            if let a = w.averageHR { parts.append(String(format: "avg %.0f", a)) }
            if let p = w.peakHR { parts.append(String(format: "peak %.0f", p)) }
            if let r = w.recovery1 { parts.append(String(format: "recovery %.0f bpm", r)) }
            items.append(TimelineItem(date: w.start, kind: .workout, title: WorkoutType.name(w.activityType),
                                      detail: parts.joined(separator: " · ")))
        }
        for e in entries where act.contains(e.date) {
            switch e.kind {
            case .caffeine:
                items.append(TimelineItem(date: e.date, kind: .caffeine, title: e.label.isEmpty ? "Caffeine" : e.label,
                                          detail: String(format: "%.0f mg", e.amount)))
            case .water:
                items.append(TimelineItem(date: e.date, kind: .water, title: e.label.isEmpty ? "Water" : e.label,
                                          detail: String(format: "%.0f ml", e.amount)))
            }
        }
        if let tags = journal[day] {
            items.append(TimelineItem(date: act.end.addingTimeInterval(-60), kind: .journal, title: "Journal",
                                      detail: tags.isEmpty ? "Nothing notable" : tags.sorted().joined(separator: ", ")))
        }
        for p in statusPeriods where p.start == day {
            items.append(TimelineItem(date: act.start, kind: .status, title: "Marked \(p.kind.rawValue)",
                                      detail: p.end.map { "Until \($0)" } ?? "Ongoing"))
        }
        return DayTimeline(day: day, items: items.sorted { ($0.date, $0.kind.rawValue) < ($1.date, $1.kind.rawValue) })
    }
}
