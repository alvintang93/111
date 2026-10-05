import Foundation

/// Turns cached `DayRecord`s into scores. Pure and deterministic: the same
/// records, settings, parameters and `asOf` always produce the same brief.
public struct Engine {
    public let calendar: Calendar
    public let today: Day
    public let settings: UserSettings
    public let params: ModelParameters
    public let hrMax: Double
    public let hrRest: Double
    public let hrMaxSource: String
    public let hrRestSource: String
    /// Wall-clock time of evaluation. When set, today's score is withheld until
    /// the overnight window has closed. Nil disables that check (history, tests).
    public let asOf: Date?

    /// Marked periods (unwell, sore, travel).
    public let statusPeriods: [StatusPeriod]
    /// Days inside any status period: left out of every personal baseline.
    let excluded: Set<Day>

    /// Contiguous days from the oldest record to today.
    let days: [Day]
    let records: [Day: DayRecord]
    /// Aligned with `days`, ending yesterday (today is still in progress).
    let loadPoints: [LoadPoint]
    var todayIndex: Int { days.count - 1 }

    final class Cache {
        var raw: [Int: RawRecovery] = [:]
    }
    let cache = Cache()

    public init(records input: [DayRecord], today: Day, settings: UserSettings,
                calendar: Calendar, params: ModelParameters = .standard, asOf: Date? = nil,
                statusPeriods: [StatusPeriod] = []) {
        var map: [Day: DayRecord] = [:]
        for r in input where r.day <= today { map[r.day] = r }
        let first = map.keys.min() ?? today
        let days = Day.range(from: first, to: today, calendar: calendar)

        let hrRestWindow = days.suffix(31).dropLast()
        let appleRHR = hrRestWindow.compactMap { map[$0]?.appleRestingHR }
        let sleepingHR = hrRestWindow.compactMap { map[$0]?.sleepingHR }
        let hrRest: Double
        let hrRestSource: String
        if appleRHR.count >= 7, let m = Stats.median(appleRHR) {
            hrRest = m
            hrRestSource = "Apple resting HR, median of \(appleRHR.count) days"
        } else if sleepingHR.count >= 7, let m = Stats.median(sleepingHR) {
            hrRest = m
            hrRestSource = "Sleeping HR, median of \(sleepingHR.count) nights (Apple resting HR < 7 days)"
        } else {
            hrRest = 60
            hrRestSource = "Default 60 bpm (fewer than 7 days of resting/sleeping HR)"
        }
        let hrMax = settings.resolvedHRMax
        let hrMaxSource: String
        if let h = settings.hrMaxOverride, h > 100 {
            hrMaxSource = "Measured (Settings)"
        } else if let a = settings.age, a > 0 {
            hrMaxSource = "208 - 0.7 x age (\(a))"
        } else {
            hrMaxSource = "Default 190 bpm (age unknown)"
        }

        let excluded = Set(days.filter { d in statusPeriods.contains { $0.covers(d) } })
        let paused = Set(days.filter { d in statusPeriods.contains { $0.kind.pausesLoad && $0.covers(d) } })
        let completed = Array(days.dropLast())
        let loads: [Double?] = completed.map { d in
            guard let r = map[d], r.coverageHours >= params.minCoverageHours else { return nil }
            return r.activity.trimp(hrRest: hrRest, hrMax: hrMax, sex: settings.sex,
                                    floorHRR: params.activityFloorHRR)
        }

        self.calendar = calendar
        self.today = today
        self.settings = settings
        self.params = params
        self.hrMax = hrMax
        self.hrRest = hrRest
        self.hrMaxSource = hrMaxSource
        self.hrRestSource = hrRestSource
        self.asOf = asOf
        self.statusPeriods = statusPeriods
        self.excluded = excluded
        self.days = days
        self.records = map
        self.loadPoints = LoadModel.run(days: completed, loads: loads, paused: paused, params: params)
    }

    func windows(at i: Int) -> DayWindows {
        records[days[i]]?.windows ?? .nominal(for: days[i], calendar: calendar)
    }

    // MARK: - Load

    func trimp(_ record: DayRecord) -> Double? {
        record.activity.trimp(hrRest: hrRest, hrMax: hrMax, sex: settings.sex,
                              floorHRR: params.activityFloorHRR)
    }

    /// Chronic load usable as a denominator, as of the end of `days[index]`.
    func eligibleCTL(throughIndex index: Int) -> LoadPoint? {
        guard index >= 0, index < loadPoints.count,
              index + 1 >= params.minLoadHistoryDays,
              loadPoints[index].ctl >= params.minCTLForTargets else { return nil }
        return loadPoints[index]
    }

    func acwr(throughIndex index: Int) -> Double? {
        eligibleCTL(throughIndex: index).map { $0.atl / $0.ctl }
    }

    // MARK: - Sleep

    /// Need for the night ending on `days[n]` (n may be todayIndex + 1 for tonight).
    func sleepNeed(nightIndex n: Int, priorDayLoadOverride: Double? = nil) -> SleepNeed {
        let priorNights: [TimeInterval?] = (max(0, n - params.sleepDebtNights)..<n).map { k in
            k < days.count ? records[days[k]]?.sleep?.asleep : nil
        }
        let priorDay = n - 1
        let priorLoad: Double?
        if let o = priorDayLoadOverride {
            priorLoad = o
        } else if priorDay >= 0, priorDay < loadPoints.count, loadPoints[priorDay].observed {
            priorLoad = loadPoints[priorDay].load
        } else {
            priorLoad = nil
        }
        let ctl = (n - 2 >= 0 && n - 2 < loadPoints.count) ? loadPoints[n - 2].ctl : nil
        return SleepModel.need(baseHours: settings.baseSleepNeedHours, priorNightsAsleep: priorNights,
                               priorDayLoad: priorLoad, ctl: ctl, params: params)
    }

    func sleepSummary(at i: Int) -> SleepSummary? {
        guard let night = records[days[i]]?.sleep else { return nil }
        let need = sleepNeed(nightIndex: i)
        let midpoints: [Double] = (max(0, i - params.consistencyNights + 1)...i).compactMap { k in
            guard let n = records[days[k]]?.sleep else { return nil }
            // The stored window keeps midpoints comparable across time-zone changes.
            return n.mainMidpoint.timeIntervalSince(windows(at: k).night.start) / 60
        }
        let sd = SleepModel.midpointVariability(minutesSinceWindowStart: midpoints, params: params)
        let perf = night.asleep / need.total
        let todayLoad = i == todayIndex ? records[days[i]].flatMap(trimp) : nil
        let tonight = sleepNeed(nightIndex: i + 1, priorDayLoadOverride: todayLoad ?? 0)
        return SleepSummary(
            asleepHours: night.asleep / 3600,
            needHours: need.total / 3600,
            debtHours: need.debt / 3600,
            performance: perf,
            efficiency: night.efficiency,
            midpointSDMinutes: sd,
            score: SleepModel.score(performance: perf, efficiency: night.efficiency, midpointSDMinutes: sd),
            deepMinutes: night.deep / 60,
            remMinutes: night.rem / 60,
            coreMinutes: night.core / 60,
            awakeMinutes: night.awake / 60,
            unspecifiedMinutes: night.unspecified / 60,
            onset: night.mainOnset,
            wake: night.mainWake,
            tonightNeedHours: tonight.total / 3600
        )
    }

    // MARK: - Recovery

    func baselineValues(_ key: KeyPath<DayRecord, Double?>, before i: Int) -> [Double] {
        let lo = max(0, i - params.baselineWindowDays)
        return days[lo..<i].filter { !excluded.contains($0) }.compactMap { records[$0]?[keyPath: key] }
    }

    func baseline(_ key: KeyPath<DayRecord, Double?>, before i: Int, floor: Double) -> RobustBaseline? {
        RobustBaseline(values: baselineValues(key, before: i), minCount: params.minBaselineDays, scaleFloor: floor)
    }

    public func recovery(for day: Day) -> Recovery? {
        days.firstIndex(of: day).map { recovery(at: $0) }
    }

    struct RawRecovery {
        var components: [Component]
        /// Nil whenever no score may be produced (a status without a score).
        var composite: Double?
        var confidence: Confidence
        var flags: [Flag]
        var hrvNights: Int
        var sleepingHRNights: Int
        /// Status before score-scale calibration and night-in-progress are applied.
        var dataStatus: ScoreStatus
        var missingInputs: [ComponentKind]
        var baselines: [BaselineSnapshot]
    }

    /// Components, uncalibrated composite, confidence and flags for `days[i]`.
    func rawRecovery(at i: Int) -> RawRecovery {
        if let cached = cache.raw[i] { return cached }
        let r = computeRawRecovery(at: i)
        cache.raw[i] = r
        return r
    }

    private func computeRawRecovery(at i: Int) -> RawRecovery {
        let rec = records[days[i]]
        let hrvValues = baselineValues(\.lnHRV, before: i)
        let rhrValues = baselineValues(\.sleepingHR, before: i)
        let hrvB = RobustBaseline(values: hrvValues, minCount: params.minBaselineDays, scaleFloor: params.hrvScaleFloor)
        let rhrB = RobustBaseline(values: rhrValues, minCount: params.minBaselineDays, scaleFloor: params.restingHRScaleFloor)
        let rrB = baseline(\.respiratoryRate, before: i, floor: params.respiratoryScaleFloor)
        let tempB = baseline(\.wristTemperature, before: i, floor: params.temperatureScaleFloor)
        let zc = params.zClamp

        var baselines: [BaselineSnapshot] = []
        if let b = hrvB { baselines.append(BaselineSnapshot(kind: .hrv, center: exp(b.center), scale: b.scale, count: b.count)) }
        if let b = rhrB { baselines.append(BaselineSnapshot(kind: .restingHR, center: b.center, scale: b.scale, count: b.count)) }
        if let b = rrB { baselines.append(BaselineSnapshot(kind: .respiratoryRate, center: b.center, scale: b.scale, count: b.count)) }
        if let b = tempB { baselines.append(BaselineSnapshot(kind: .wristTemperature, center: b.center, scale: b.scale, count: b.count)) }

        var comps: [Component] = []
        // Array, not Dictionary: floating-point sums must run in a fixed order
        // (Dictionary iteration order is seeded per instance).
        var rawWeights: [Double] = []
        func add(_ kind: ComponentKind, value: Double, baseline: Double?, z: Double, rawZ: Double?, weight: Double) {
            comps.append(Component(kind: kind, value: value, baseline: baseline, z: z, rawZ: rawZ, weight: 0))
            rawWeights.append(weight)
        }

        var rhrRaw: Double?, rrRaw: Double?, tempRaw: Double?
        if let x = rec?.lnHRV, let b = hrvB {
            let raw = b.z(x)
            add(.hrv, value: exp(x), baseline: exp(b.center), z: Stats.clamp(raw, -zc, zc), rawZ: raw,
                weight: params.weightHRV)
        }
        if let x = rec?.sleepingHR, let b = rhrB {
            let raw = b.z(x)
            rhrRaw = raw
            add(.restingHR, value: x, baseline: b.center, z: Stats.clamp(-raw, -zc, zc), rawZ: raw,
                weight: params.weightRestingHR)
        }
        if let night = rec?.sleep {
            let perf = night.asleep / sleepNeed(nightIndex: i).total
            add(.sleep, value: perf * 100, baseline: 100,
                z: Stats.clamp((perf - 1) / params.sleepShortfallPerSD, -zc, 1), rawZ: nil,
                weight: params.weightSleep)
        }
        if let x = rec?.respiratoryRate, let b = rrB {
            let raw = b.z(x)
            rrRaw = raw
            add(.respiratoryRate, value: x, baseline: b.center,
                z: -min(max(0, raw - params.asymmetricDeadband), zc), rawZ: raw,
                weight: params.weightRespiratory)
        }
        if let x = rec?.wristTemperature, let b = tempB {
            let raw = b.z(x)
            tempRaw = raw
            add(.wristTemperature, value: x, baseline: b.center,
                z: -min(max(0, raw - params.asymmetricDeadband), zc), rawZ: raw,
                weight: params.weightTemperature)
        }

        let totalWeight = rawWeights.reduce(0, +)
        for k in comps.indices {
            comps[k].weight = totalWeight > 0 ? rawWeights[k] / totalWeight : 0
        }

        let has = Set(comps.map(\.kind))
        let hasCore = has.contains(.hrv) || has.contains(.restingHR)
        let missing = [ComponentKind.hrv, .restingHR].filter { !has.contains($0) }

        // HRV is the primary signal: no HRV baseline, no score. A score built
        // from heart rate alone would look normal while missing its main input.
        let dataStatus: ScoreStatus
        if hrvB == nil {
            dataStatus = hrvValues.isEmpty && rhrB != nil ? .hrvUnavailable : .calibrating
        } else if !hasCore {
            dataStatus = .noOvernightData
        } else if !missing.isEmpty {
            dataStatus = .degraded
        } else {
            dataStatus = .scored
        }

        let confidence: Confidence
        if hrvB == nil {
            confidence = .calibrating
        } else if !hasCore {
            confidence = .noData
        } else if has.contains(.hrv), rec?.hrvDuringSleep == true, has.contains(.restingHR), has.contains(.sleep),
                  (hrvB?.count ?? 0) >= params.highConfidenceBaselineDays {
            confidence = .high
        } else if has.contains(.hrv), has.contains(.restingHR) || has.contains(.sleep) {
            confidence = .medium
        } else {
            confidence = .low
        }

        var flags: [Flag] = []
        if let r = rhrRaw, r >= params.elevatedVitalsZ,
           (tempRaw ?? -.infinity) >= params.elevatedVitalsZ || (rrRaw ?? -.infinity) >= params.elevatedVitalsZ {
            flags.append(.elevatedVitals)
        }
        if let b = hrvB {
            let recent = days[max(0, i - params.hrvTrendDays + 1)...i].filter { !excluded.contains($0) || $0 == days[i] }
                .compactMap { records[$0]?.lnHRV }
            if recent.count >= params.hrvTrendMinDays, let m = Stats.mean(recent),
               m < b.center - params.hrvTrendSWC * b.scale {
                flags.append(.hrvTrendLow)
            }
        }
        if let a = acwr(throughIndex: i - 1), a > params.loadSpikeACWR {
            flags.append(.loadSpike)
        }
        if sleepNeed(nightIndex: i).debt >= params.sleepDebtFlagHours * 3600 {
            flags.append(.sleepDebt)
        }

        let composite = dataStatus.hasScore ? comps.reduce(0) { $0 + $1.contribution } : nil
        return RawRecovery(components: comps, composite: composite, confidence: confidence, flags: flags,
                           hrvNights: hrvValues.count, sleepingHRNights: rhrValues.count,
                           dataStatus: dataStatus, missingInputs: hasCore ? missing : [],
                           baselines: baselines)
    }

    func composite(at i: Int) -> Double? {
        rawRecovery(at: i).composite
    }

    func compositeHistory(before i: Int) -> [Double] {
        let lo = max(0, i - params.baselineWindowDays)
        return (lo..<i).filter { !excluded.contains(days[$0]) }.compactMap { composite(at: $0) }
    }

    /// Robust centre/scale of the person's own recent composites. Without this,
    /// structural offsets (e.g. habitually sleeping below the stated need) would
    /// paint every day red: on stationary data the raw composite put 29% of days
    /// in the bottom band.
    func compositeCalibration(before i: Int) -> RobustBaseline? {
        RobustBaseline(values: compositeHistory(before: i), minCount: params.minCalibrationDays,
                       scaleFloor: params.compositeScaleFloor)
    }

    /// True once today's overnight data can be considered complete.
    func overnightClosed(at i: Int) -> Bool {
        guard i == todayIndex, let now = asOf else { return true }
        if let night = records[days[i]]?.sleep, now >= night.mainWake.addingTimeInterval(params.overnightSettleTime) {
            return true
        }
        return now >= windows(at: i).fallbackOvernight.end
    }

    func recovery(at i: Int) -> Recovery {
        let raw = rawRecovery(at: i)
        let history = compositeHistory(before: i)
        let cal = RobustBaseline(values: history, minCount: params.minCalibrationDays,
                                 scaleFloor: params.compositeScaleFloor)
        let stage: CalibrationStatus.Stage
        if raw.hrvNights < params.minBaselineDays {
            stage = .insufficientHRV
        } else {
            stage = cal == nil ? .provisionalScale : .calibrated
        }
        let calibration = CalibrationStatus(
            stage: stage, hrvNights: raw.hrvNights, hrvNightsRequired: params.minBaselineDays,
            sleepingHRNights: raw.sleepingHRNights,
            compositeDays: history.count, compositeDaysRequired: params.minCalibrationDays)

        var status = raw.dataStatus
        if !overnightClosed(at: i) {
            status = .nightInProgress
        } else if status == .scored && cal == nil {
            status = .provisional
        }

        var score: Int?, relative: Double?, calibrationDays = 0
        var band = RecoveryBand.unknown
        if status.hasScore, let c = raw.composite {
            let z: Double
            if let cal {
                z = cal.z(c)
                calibrationDays = cal.count
            } else {
                // Early history: assume independent unit-variance components.
                let sd = raw.components.reduce(0) { $0 + $1.weight * $1.weight }.squareRoot()
                z = sd > 0 ? c / sd : 0
            }
            relative = z
            let s = min(max(Int((100 * Stats.normalCDF(z)).rounded()), 1), 99)
            score = s
            band = s >= params.primedThreshold ? .primed : (s <= params.depletedThreshold ? .depleted : .steady)
        }
        return Recovery(score: score, band: band, composite: status.hasScore ? raw.composite : nil,
                        relativeZ: relative, calibrationDays: calibrationDays, confidence: raw.confidence,
                        components: raw.components, flags: raw.flags, baselineDays: raw.hrvNights,
                        status: status, calibration: calibration,
                        statusDetail: detail(for: status, raw: raw, calibration: calibration),
                        missingInputs: raw.missingInputs)
    }

    func detail(for status: ScoreStatus, raw: RawRecovery, calibration c: CalibrationStatus) -> String {
        let missing = raw.missingInputs.map { $0 == .hrv ? "HRV" : "sleeping heart rate" }.joined(separator: " and ")
        switch status {
        case .nightInProgress:
            return "Overnight window still open. A recommendation appears after you wake, or once the overnight window ends."
        case .hrvUnavailable:
            return "No HRV readings in the last \(params.baselineWindowDays) days although heart rate is recorded. Check Health access for Heart Rate Variability."
        case .calibrating:
            return "Calibrating: \(c.hrvNights) of \(c.hrvNightsRequired) nights with HRV."
        case .noOvernightData:
            return "No overnight HRV or sleeping heart rate for last night."
        case .degraded:
            return "Partial data: no \(missing) for last night. Push is disabled."
        case .provisional:
            return "Score scale still calibrating (\(c.compositeDays) of \(c.compositeDaysRequired) days). Push is disabled."
        case .scored:
            return "Full overnight inputs and calibrated score scale."
        }
    }

    // MARK: - Plan

    func directive(for r: Recovery, on day: Day? = nil) -> (Directive, [String], [RuleCheck]) {
        var trace: [RuleCheck] = []
        func check(_ rule: String, _ passed: Bool, _ detail: String) {
            trace.append(RuleCheck(rule: rule, passed: passed, detail: detail))
        }
        check("Score available", r.status.hasScore, "\(r.status.rawValue): \(r.statusDetail)")
        guard r.status.hasScore, let s = r.score else {
            let d: Directive
            switch r.status {
            case .nightInProgress: d = .pending
            case .calibrating: d = .calibrating
            case .hrvUnavailable, .noOvernightData, .degraded, .provisional, .scored: d = .noData
            }
            return (d, [r.statusDetail], trace)
        }
        func z(_ k: ComponentKind) -> String {
            r.components.first { $0.kind == k }?.rawZ.map { String(format: "%+.1f", $0) } ?? "n/a"
        }
        let vitals = r.flags.contains(.elevatedVitals)
        check("Elevated overnight vitals -> Rest", vitals,
              String(format: "needs sleeping HR z >= %.1f and temp or resp z >= %.1f; ", params.elevatedVitalsZ, params.elevatedVitalsZ)
                + "HR \(z(.restingHR)), temp \(z(.wristTemperature)), resp \(z(.respiratoryRate))")
        if vitals {
            return (.rest, ["Sleeping heart rate and temperature or respiration are well above your usual range."], trace)
        }
        check("Score <= \(params.recoverScore) -> Recover", s <= params.recoverScore, "score \(s)")
        if s <= params.recoverScore {
            return (.recover, ["Recovery well below your typical day."], trace)
        }
        let trendLow = r.flags.contains(.hrvTrendLow)
        let debt = r.flags.contains(.sleepDebt)
        let confirmed = s <= params.depletedThreshold && (trendLow || debt)
        check("Score <= \(params.depletedThreshold) confirmed by HRV trend or sleep debt -> Recover", confirmed,
              "score \(s); HRV trend low: \(trendLow); sleep debt: \(debt)")
        if confirmed {
            return (.recover, [trendLow ? "Low day confirmed by 7-day HRV trend." : "Low day confirmed by sleep debt."], trace)
        }
        if s <= params.depletedThreshold {
            return (.maintain, ["Below-typical day without trend confirmation: train as planned, cap intensity."], trace)
        }
        check("Score >= \(params.primedThreshold) -> Push candidate", s >= params.primedThreshold, "score \(s)")
        guard s >= params.primedThreshold else { return (.maintain, [], trace) }

        // Asymmetric loss: training hard while fatigued costs more than an easy
        // day while fresh, so weak or conflicting evidence demotes "push".
        let spike = r.flags.contains(.loadSpike)
        let blocking = StatusPeriod.kinds(on: day ?? today, in: statusPeriods).filter(\.blocksPush)
        let demotions: [(String, Bool, String, String)] = [
            ("Push needs full inputs and calibrated scale", r.status == .scored, r.status.rawValue,
             "Push demoted: \(r.statusDetail)"),
            ("Push needs confidence above low", r.confidence != .low, r.confidence.rawValue,
             "Push demoted: low data confidence."),
            ("Push blocked by low HRV trend", !trendLow, "HRV trend low: \(trendLow)",
             "Push demoted: 7-day HRV trend below normal range."),
            ("Push blocked by load spike", !spike, "load spike: \(spike)", "Push demoted: acute load spike."),
            ("Push blocked by sleep debt", !debt, "sleep debt: \(debt)", "Push demoted: sleep debt."),
            ("Push blocked while marked unwell or sore", blocking.isEmpty,
             "status: \(blocking.map(\.rawValue).joined(separator: ", "))",
             "Push is off while you're marked \(blocking.map(\.rawValue).joined(separator: " and "))."),
        ]
        for (rule, ok, detail, reason) in demotions {
            check(rule, ok, detail)
            if !ok { return (.maintain, [reason], trace) }
        }
        return (.push, [], trace)
    }

    func plan(recovery r: Recovery) -> Plan {
        let (action, initialReasons, trace) = directive(for: r)
        var reasons = initialReasons
        var low: Double?, high: Double?, ceiling: Double?
        if let lp = eligibleCTL(throughIndex: loadPoints.count - 1) {
            ceiling = LoadModel.ceiling(atl: lp.atl, ctl: lp.ctl, ratio: settings.acwrCeiling, params: params)
            let band: (Double, Double)?
            switch action {
            case .push: band = (1.0, 1.5)
            case .maintain: band = (0.6, 1.0)
            case .recover: band = (0, 0.5)
            case .rest: band = (0, 0.3)
            case .calibrating, .noData, .pending: band = nil
            }
            if let b = band {
                let (lo, hi) = b
                var h = hi * lp.ctl
                if let c = ceiling, c < h {
                    h = c
                    reasons.append("Upper target capped so ATL/CTL stays <= \(String(format: "%.2f", settings.acwrCeiling)).")
                }
                low = min(lo * lp.ctl, h)
                high = h
            }
        } else {
            reasons.append("Load targets need \(params.minLoadHistoryDays) days of history.")
        }
        return Plan(directive: action, targetLow: low, targetHigh: high, ceiling: ceiling, reasons: reasons, trace: trace)
    }

    // MARK: - Audit

    func audit(todayRecovery: Recovery, todayDirective: Directive) -> BriefAudit {
        let i = todayIndex
        let windowStart = max(0, i - params.baselineWindowDays + 1)
        let windowDays = Array(days[windowStart...i])
        let last7 = Array(days[max(0, i - 6)...i])

        func hasData(_ r: DayRecord?, _ input: HealthInput) -> Bool {
            (r?.ingestion[input].accepted ?? 0) > 0
        }
        let inputs: [InputAvailability] = HealthInput.allCases.map { input in
            var acc = 0, dup = 0, imp = 0, fut = 0
            var earliest: Date?, latest: Date?
            for d in windowDays {
                guard let st = records[d]?.ingestion[input] else { continue }
                acc += st.accepted
                dup += st.duplicates
                imp += st.implausible
                fut += st.future
                if let e = st.earliest { earliest = min(earliest ?? e, e) }
                if let l = st.latest { latest = max(latest ?? l, l) }
            }
            return InputAvailability(
                input: input,
                daysWithDataLast7: last7.filter { hasData(records[$0], input) }.count,
                daysWithDataInWindow: windowDays.filter { hasData(records[$0], input) }.count,
                windowDays: windowDays.count, accepted: acc, duplicates: dup, implausible: imp, future: fut,
                earliestSample: earliest, latestSample: latest)
        }

        let w7 = last7.compactMap { records[$0]?.workouts }
        let w28 = days[max(0, i - 27)...i].compactMap { records[$0]?.workouts }
        let coverages = w7.compactMap(\.heartRateCoverage)
        let latestWorkout = days.compactMap { records[$0]?.workouts.latestEnd }.max()
        var zones: [String] = []
        for z in days.suffix(14).compactMap({ records[$0]?.windows?.timeZoneID }) where !zones.contains(z) {
            zones.append(z)
        }

        return BriefAudit(
            asOf: asOf,
            recordCount: records.count,
            earliestRecordDay: records.keys.min(),
            latestRecordDay: records.keys.max(),
            inputs: inputs,
            baselines: rawRecovery(at: i).baselines,
            thresholds: thresholds(),
            hrMaxSource: hrMaxSource,
            hrRestSource: hrRestSource,
            workoutsLast7: w7.reduce(0) { $0 + $1.started },
            workoutsLast28: w28.reduce(0) { $0 + $1.started },
            latestWorkoutEnd: latestWorkout,
            workoutHRCoverageLast7: Stats.mean(coverages),
            recentTimeZones: zones,
            distribution: distribution(from: windowStart, todayRecovery: todayRecovery, todayDirective: todayDirective))
    }

    func thresholds() -> ThresholdSnapshot {
        ThresholdSnapshot(
            primedScore: params.primedThreshold, depletedScore: params.depletedThreshold,
            recoverScore: params.recoverScore, elevatedVitalsZ: params.elevatedVitalsZ,
            hrvTrendSWC: params.hrvTrendSWC, loadSpikeACWR: params.loadSpikeACWR,
            sleepDebtHours: params.sleepDebtFlagHours, minHRVNights: params.minBaselineDays,
            minCompositeDays: params.minCalibrationDays, baselineWindowDays: params.baselineWindowDays,
            acwrCeiling: settings.acwrCeiling,
            weights: [
                WeightSnapshot(kind: .hrv, weight: params.weightHRV),
                WeightSnapshot(kind: .restingHR, weight: params.weightRestingHR),
                WeightSnapshot(kind: .sleep, weight: params.weightSleep),
                WeightSnapshot(kind: .respiratoryRate, weight: params.weightRespiratory),
                WeightSnapshot(kind: .wristTemperature, weight: params.weightTemperature),
            ])
    }

    /// Re-evaluates the rule chain for every day in the window with the same
    /// functions that produce today's recommendation. Nothing here feeds back
    /// into thresholds.
    func distribution(from start: Int, todayRecovery: Recovery, todayDirective: Directive) -> DecisionDistribution {
        var directiveCounts = Array(repeating: 0, count: Directive.allCases.count)
        var statusCounts = Array(repeating: 0, count: ScoreStatus.allCases.count)
        var histogram = Array(repeating: 0, count: 10)
        var scores: [Double] = []
        var zs: [ComponentKind: [Double]] = [:]
        for k in start...todayIndex {
            let r = k == todayIndex ? todayRecovery : recovery(at: k)
            let d = k == todayIndex ? todayDirective : directive(for: r, on: days[k]).0
            directiveCounts[Directive.allCases.firstIndex(of: d)!] += 1
            statusCounts[ScoreStatus.allCases.firstIndex(of: r.status)!] += 1
            if let s = r.score {
                histogram[min(s / 10, 9)] += 1
                scores.append(Double(s))
                for c in r.components { zs[c.kind, default: []].append(c.z) }
            }
        }
        return DecisionDistribution(
            from: days[start], to: days[todayIndex], days: todayIndex - start + 1,
            directives: zip(Directive.allCases, directiveCounts).map { CountEntry(key: $0.rawValue, count: $1) },
            statuses: zip(ScoreStatus.allCases, statusCounts).map { CountEntry(key: $0.rawValue, count: $1) },
            scoreHistogram: histogram,
            scoreMean: Stats.mean(scores),
            scoreSD: Stats.standardDeviation(scores),
            components: ComponentKind.allCases.map { kind in
                let v = zs[kind] ?? []
                return ComponentStats(kind: kind, n: v.count, mean: Stats.mean(v), sd: Stats.standardDeviation(v),
                                      min: v.min(), max: v.max())
            })
    }

    // MARK: - Brief

    func hrvDeviations() -> [Day: Double] {
        var out: [Day: Double] = [:]
        for i in days.indices {
            guard let x = records[days[i]]?.lnHRV,
                  let b = baseline(\.lnHRV, before: i, floor: params.hrvScaleFloor) else { continue }
            out[days[i]] = x - b.center
        }
        return out
    }

    public func brief(journal: [Day: Set<String>] = [:], intake: [IntakeEntry] = [],
                      lifestyle: LifestyleSettings = LifestyleSettings(), historyDays: Int = 14,
                      generatedAt: Date = Date(), dataSyncedAt: Date? = nil) -> DailyBrief {
        let i = todayIndex
        let rec = recovery(at: i)
        let todayRecord = records[today]
        let last = loadPoints.last
        let eligible = eligibleCTL(throughIndex: loadPoints.count - 1)
        let load = LoadSummary(
            todayLoad: todayRecord.flatMap(trimp),
            todayCoverageHours: todayRecord?.coverageHours ?? 0,
            todayZoneMinutes: (todayRecord?.activity.zoneSeconds(hrRest: hrRest, hrMax: hrMax)
                ?? Array(repeating: 0, count: 6)).map { $0 / 60 },
            atl: last?.atl,
            ctl: last?.ctl,
            acwr: eligible.map { $0.atl / $0.ctl },
            tsb: last.map { $0.ctl - $0.atl },
            historyDays: loadPoints.count,
            unobservedDaysLast28: loadPoints.suffix(28).filter { !$0.observed }.count
        )

        let history: [HistoryPoint] = days.indices.suffix(historyDays).map { k in
            let d = days[k]
            let l: Double?
            if k == i {
                l = todayRecord.flatMap(trimp)
            } else {
                l = loadPoints[k].observed ? loadPoints[k].load : nil
            }
            return HistoryPoint(day: d,
                                recoveryScore: k == i ? rec.score : recovery(at: k).score,
                                load: l,
                                hrvMs: records[d]?.lnHRV.map(exp),
                                ctl: k < loadPoints.count ? loadPoints[k].ctl : last?.ctl)
        }

        let plan = plan(recovery: rec)
        let sleep = sleepSummary(at: i)
        let strain = strainSummary(at: i, plan: plan)
        let stress = stressSummary(at: i)
        let now = asOf ?? generatedAt
        return DailyBrief(
            day: today,
            generatedAt: generatedAt,
            recovery: rec,
            sleep: sleep,
            load: load,
            plan: plan,
            history: history,
            tagImpacts: TagAnalysis.impacts(journal: journal, hrvDeviation: hrvDeviations(),
                                            calendar: calendar, params: params),
            hrMaxUsed: hrMax,
            hrRestUsed: hrRest,
            dataSyncedAt: dataSyncedAt,
            audit: audit(todayRecovery: rec, todayDirective: plan.directive),
            strain: strain,
            stress: stress,
            energy: energySummary(at: i, recovery: rec, sleep: sleep, strain: strain, stress: stress, now: now),
            intake: intakeSummary(at: i, entries: intake, lifestyle: lifestyle),
            heartRateRecovery: heartRateRecoverySummary(at: i),
            statuses: StatusPeriod.kinds(on: today, in: statusPeriods),
            timelines: (max(0, i - 1)...i).map { timeline(at: $0, journal: journal, entries: intake) }
        )
    }
}
