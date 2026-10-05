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

    /// Activities for the day, merged across Health and Margin's logs (see `ActivityReconciler`).
    func activities(at i: Int, strength: StrengthLog?, activityLog: ActivityLog?, zones: ZoneSettings = .standard) -> [ActivityEntry] {
        let act = activityWindow(at: i)
        let health = records[days[i]]?.workoutDetails ?? []
        let logged = (activityLog?.activities ?? []).filter { act.contains($0.start) }
        let sessions = (strength?.sessions ?? []).filter { act.contains($0.start) && !$0.sets.isEmpty }
        let ref = eligibleCTL(throughIndex: i - 1)?.ctl ?? params.strainFallbackReference
        return ActivityReconciler.reconcile(health: health, logged: logged, strength: sessions,
                                            exerciseName: { strength?.exercise($0)?.name }).map { e in
            var e = e
            e.analysis = e.health.map {
                WorkoutAnalysis.make($0, hrRest: hrRest, hrMax: hrMax, sex: settings.sex, floorHRR: params.activityFloorHRR,
                                     zones: zones, strainReference: ref)
            }
            return e
        }
    }

    /// The day's chronological record. Every event has a stable id derived from
    /// its source record, and the list is de-duplicated by id.
    func timeline(at i: Int, journal: [Day: Set<String>], entries: [IntakeEntry], strength: StrengthLog? = nil,
                  activityLog: ActivityLog? = nil, biomarkers: BiomarkerInput? = nil, now: Date? = nil) -> DayTimeline {
        let day = days[i]
        let act = activityWindow(at: i)
        let asOf = now ?? asOf ?? act.end
        var items: [TimelineItem] = []
        func hm(_ seconds: TimeInterval) -> String {
            let m = Int((seconds / 60).rounded())
            return "\(m / 60)h \(String(format: "%02d", m % 60))m"
        }
        let rec = records[day]
        if let n = rec?.sleep {
            items.append(TimelineItem(id: "sleep-\(day)", date: n.mainOnset, kind: .sleep, title: "Asleep",
                                      detail: "\(hm(n.asleep)) · deep \(hm(n.deep)) · REM \(hm(n.rem)) · core \(hm(n.core + n.unspecified))",
                                      source: "Apple Health"))
            items.append(TimelineItem(id: "wake-\(day)", date: n.mainWake, kind: .wake, title: "Woke",
                                      detail: n.efficiency.map { String(format: "Efficiency %.0f%%", $0 * 100) } ?? "", source: "Apple Health"))
        }
        // Overnight readings: the exact values the recovery score uses for this day.
        if let r = rec {
            var parts: [String] = []
            let raw = rawRecovery(at: i)
            if let x = r.lnHRV {
                var p = String(format: "HRV %.0f ms (%d reading%@)", exp(x), r.hrvSampleCount, r.hrvSampleCount == 1 ? "" : "s")
                if let b = raw.baselines.first(where: { $0.kind == .hrv }) { p += String(format: ", %+.0f%% vs usual", (exp(x) / b.center - 1) * 100) }
                parts.append(p)
            }
            if let h = r.sleepingHR { parts.append(String(format: "sleeping HR %.0f", h)) }
            if let rr = r.respiratoryRate { parts.append(String(format: "respiration %.1f/min", rr)) }
            if let t = r.wristTemperature {
                if let b = raw.baselines.first(where: { $0.kind == .wristTemperature }) {
                    parts.append(String(format: "wrist temp %+.2f °C vs usual", t - b.center))
                } else {
                    parts.append(String(format: "wrist temp %.2f °C", t))
                }
            }
            if let n = r.sleep, let spo = biomarkers?.clean(.spo2, asOf: asOf).samples
                .filter({ $0.start >= n.mainOnset && $0.start <= n.mainWake }), let m = Stats.median(spo.map(\.value)) {
                parts.append(String(format: "SpO₂ median %.0f%% (%d)", m, spo.count))
            }
            if !parts.isEmpty {
                let at = r.sleep?.mainWake ?? day.date(hour: 7, calendar: calendar)
                items.append(TimelineItem(id: "vitals-\(day)", date: at, kind: .vitals, title: "Overnight readings",
                                          detail: parts.joined(separator: " · "), source: "Apple Health"))
            }
        }
        // Recovery as issued for the day.
        let r = i == todayIndex && overnightClosed(at: i) == false ? nil : recovery(at: i)
        if let r, r.status != .nightInProgress {
            let d = directive(for: r, on: day).0
            let title = r.score.map { "Recovery \($0)" } ?? r.status.rawValue.capitalized
            let at = (rec?.sleep?.mainWake ?? day.date(hour: 7, calendar: calendar)).addingTimeInterval(params.overnightSettleTime)
            items.append(TimelineItem(id: "recovery-\(day)", date: min(at, max(asOf, act.start)), kind: .recovery, title: title,
                                      detail: d.isRecommendation ? "Recommendation: \(d.rawValue)" : r.statusDetail, source: "Margin"))
        }
        // Activities, merged across Health and Margin.
        for e in activities(at: i, strength: strength, activityLog: activityLog) {
            var parts = [String(format: "%.0f min", e.end.timeIntervalSince(e.start) / 60)]
            if let s = e.strength {
                let working = s.sets.filter { !$0.warmup }
                parts.append("\(working.count) sets")
            }
            if let h = e.health {
                if let a = h.averageHR { parts.append(String(format: "avg %.0f", a)) }
                if let p = h.peakHR { parts.append(String(format: "peak %.0f", p)) }
                if let rc = h.recovery1 { parts.append(String(format: "recovery %.0f bpm", rc)) }
            }
            if let rpe = e.logged?.rpe ?? e.strength?.rpe { parts.append("RPE \(rpe)") }
            if let notes = e.logged?.notes, !notes.isEmpty { parts.append(notes) }
            let kind: TimelineItem.Kind = e.kind == .strength ? .strength : (e.kind == .logged ? .activity : .workout)
            let source: String
            switch (e.health != nil, e.kind) {
            case (true, .healthWorkout): source = e.health?.source ?? "Apple Health"
            case (true, _): source = "Margin + Apple Health"
            default: source = "Margin"
            }
            items.append(TimelineItem(id: e.id, date: e.start, kind: kind, title: e.title, detail: parts.joined(separator: " · "),
                                      source: source))
        }
        // Strain milestones from the day's hourly load.
        if let slices = rec?.hours, !slices.isEmpty {
            let ref = (eligibleCTL(throughIndex: i - 1)?.ctl) ?? params.strainFallbackReference
            var cumulative = 0.0
            var next = [25, 50, 75]
            for sl in slices.sorted(by: { $0.hour < $1.hour }) {
                cumulative += sl.trimp(hrRest: hrRest, hrMax: hrMax, sex: settings.sex, floorHRR: params.activityFloorHRR)
                let score = StrainModel.score(load: cumulative, reference: ref)
                while let t = next.first, score >= Double(t) {
                    next.removeFirst()
                    let at = min(act.start.addingTimeInterval(Double(sl.hour + 1) * 3600), act.end)
                    items.append(TimelineItem(id: "strain-\(day)-\(t)", date: at, kind: .strain, title: "Strain reached \(t)",
                                              detail: t == 50 ? "A typical day's load for you" : "", source: "Margin"))
                }
            }
        }
        for e in entries where act.contains(e.date) {
            switch e.kind {
            case .caffeine:
                items.append(TimelineItem(id: "intake-\(e.id.uuidString)", date: e.date, kind: .caffeine,
                                          title: e.label.isEmpty ? "Caffeine" : e.label, detail: String(format: "%.0f mg", e.amount), source: "Margin"))
            case .water:
                items.append(TimelineItem(id: "intake-\(e.id.uuidString)", date: e.date, kind: .water,
                                          title: e.label.isEmpty ? "Water" : e.label, detail: String(format: "%.0f ml", e.amount), source: "Margin"))
            }
        }
        // Body measurements recorded that day.
        if let bio = biomarkers {
            let kinds: [(BiomarkerKind, String, String, Int)] = [(.bodyMass, "Weight", "kg", 1), (.bodyFat, "Body fat", "%", 1),
                                                                  (.leanMass, "Lean mass", "kg", 1), (.vo2Max, "VO₂ max", "mL/kg/min", 1)]
            for (k, name, unit, digits) in kinds {
                for s in bio.clean(k, asOf: asOf).samples where dayFor(s.start) == day {
                    items.append(TimelineItem(id: "m-\(k.rawValue)-\(Int(s.start.timeIntervalSinceReferenceDate))", date: s.start,
                                              kind: .measurement, title: name, detail: String(format: "%.\(digits)f %@", s.value, unit),
                                              source: s.source ?? "Apple Health"))
                }
            }
            let dia = Dictionary(bio.clean(.diastolic, asOf: asOf).samples.map { ($0.start, $0.value) }, uniquingKeysWith: { a, _ in a })
            for s in bio.clean(.systolic, asOf: asOf).samples where dayFor(s.start) == day {
                guard let d = dia[s.start] else { continue }
                items.append(TimelineItem(id: "m-bp-\(Int(s.start.timeIntervalSinceReferenceDate))", date: s.start, kind: .measurement,
                                          title: "Blood pressure", detail: String(format: "%.0f/%.0f mmHg", s.value, d), source: s.source ?? "Apple Health"))
            }
        }
        if let tags = journal[day] {
            items.append(TimelineItem(id: "journal-\(day)", date: act.end.addingTimeInterval(-60), kind: .journal, title: "Journal",
                                      detail: tags.isEmpty ? "Nothing notable" : tags.sorted().joined(separator: ", "), source: "Margin"))
        }
        for p in statusPeriods {
            if p.start == day {
                items.append(TimelineItem(id: "status-\(p.id.uuidString)-start", date: act.start, kind: .status,
                                          title: "Marked \(p.kind.rawValue)", detail: p.end.map { "Until \($0)" } ?? "Ongoing", source: "Margin"))
            }
            if let e = p.end, e.adding(1, calendar: calendar) == day {
                items.append(TimelineItem(id: "status-\(p.id.uuidString)-end", date: act.start, kind: .status,
                                          title: "\(p.kind.rawValue.capitalized) ended", detail: "Baselines include days from here on", source: "Margin"))
            }
        }
        return DayTimeline(day: day, items: TimelineItem.ordered(items.filter { $0.date <= max(asOf, act.start) || $0.kind == .journal }))
    }
}
