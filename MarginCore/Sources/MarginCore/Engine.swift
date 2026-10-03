import Foundation

/// Turns cached `DayRecord`s into scores. Pure and deterministic: the same
/// records, settings and parameters always produce the same brief.
public struct Engine {
    public let calendar: Calendar
    public let today: Day
    public let settings: UserSettings
    public let params: ModelParameters
    public let hrMax: Double
    public let hrRest: Double

    /// Contiguous days from the oldest record to today.
    let days: [Day]
    let records: [Day: DayRecord]
    /// Aligned with `days`, ending yesterday (today is still in progress).
    let loadPoints: [LoadPoint]
    var todayIndex: Int { days.count - 1 }

    final class Cache {
        var composites: [Int: Double?] = [:]
    }
    let cache = Cache()

    public init(records input: [DayRecord], today: Day, settings: UserSettings,
                calendar: Calendar, params: ModelParameters = .standard) {
        var map: [Day: DayRecord] = [:]
        for r in input where r.day <= today { map[r.day] = r }
        let first = map.keys.min() ?? today
        let days = Day.range(from: first, to: today, calendar: calendar)

        let hrRestWindow = days.suffix(31).dropLast()
        let appleRHR = hrRestWindow.compactMap { map[$0]?.appleRestingHR }
        let sleepingHR = hrRestWindow.compactMap { map[$0]?.sleepingHR }
        let hrRest: Double
        if appleRHR.count >= 7, let m = Stats.median(appleRHR) {
            hrRest = m
        } else if sleepingHR.count >= 7, let m = Stats.median(sleepingHR) {
            hrRest = m
        } else {
            hrRest = 60
        }
        let hrMax = settings.resolvedHRMax

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
        self.days = days
        self.records = map
        self.loadPoints = LoadModel.run(days: completed, loads: loads, params: params)
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
            return n.mainMidpoint.timeIntervalSince(days[k].nightWindow(calendar: calendar).start) / 60
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

    func baseline(_ key: KeyPath<DayRecord, Double?>, before i: Int, floor: Double) -> RobustBaseline? {
        let lo = max(0, i - params.baselineWindowDays)
        let values = days[lo..<i].compactMap { records[$0]?[keyPath: key] }
        return RobustBaseline(values: values, minCount: params.minBaselineDays, scaleFloor: floor)
    }

    public func recovery(for day: Day) -> Recovery? {
        days.firstIndex(of: day).map { recovery(at: $0) }
    }

    struct RawRecovery {
        var components: [Component]
        var composite: Double?
        var confidence: Confidence
        var flags: [Flag]
        var baselineDays: Int
    }

    /// Components, uncalibrated composite, confidence and flags for `days[i]`.
    func rawRecovery(at i: Int) -> RawRecovery {
        let rec = records[days[i]]
        let hrvB = baseline(\.lnHRV, before: i, floor: params.hrvScaleFloor)
        let rhrB = baseline(\.sleepingHR, before: i, floor: params.restingHRScaleFloor)
        let rrB = baseline(\.respiratoryRate, before: i, floor: params.respiratoryScaleFloor)
        let tempB = baseline(\.wristTemperature, before: i, floor: params.temperatureScaleFloor)
        let zc = params.zClamp

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
        let confidence: Confidence
        if hrvB == nil && rhrB == nil {
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
        if let r = rhrRaw, r >= params.illnessZ,
           (tempRaw ?? -.infinity) >= params.illnessZ || (rrRaw ?? -.infinity) >= params.illnessZ {
            flags.append(.illnessWatch)
        }
        if let b = hrvB {
            let recent = days[max(0, i - params.hrvTrendDays + 1)...i].compactMap { records[$0]?.lnHRV }
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

        let composite = hasCore && confidence != .calibrating
            ? comps.reduce(0) { $0 + $1.contribution } : nil
        return RawRecovery(components: comps, composite: composite, confidence: confidence,
                           flags: flags, baselineDays: hrvB?.count ?? 0)
    }

    func composite(at i: Int) -> Double? {
        if let cached = cache.composites[i] { return cached }
        let c = rawRecovery(at: i).composite
        cache.composites[i] = .some(c)
        return c
    }

    /// Robust centre/scale of the person's own recent composites. Without this,
    /// structural offsets (e.g. habitually sleeping below the stated need) would
    /// paint every day red: on stationary data the raw composite put 29% of days
    /// in the bottom band.
    func compositeCalibration(before i: Int) -> RobustBaseline? {
        let lo = max(0, i - params.baselineWindowDays)
        let history = (lo..<i).compactMap { composite(at: $0) }
        return RobustBaseline(values: history, minCount: params.minCalibrationDays,
                              scaleFloor: params.compositeScaleFloor)
    }

    func recovery(at i: Int) -> Recovery {
        let raw = rawRecovery(at: i)
        var score: Int?, relative: Double?, calibrationDays = 0
        var band = RecoveryBand.unknown
        if let c = raw.composite {
            let z: Double
            if let cal = compositeCalibration(before: i) {
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
        return Recovery(score: score, band: band, composite: raw.composite, relativeZ: relative,
                        calibrationDays: calibrationDays, confidence: raw.confidence,
                        components: raw.components, flags: raw.flags, baselineDays: raw.baselineDays)
    }

    // MARK: - Plan

    func directive(for r: Recovery) -> (Directive, [String]) {
        var reasons: [String] = []
        switch r.confidence {
        case .calibrating:
            return (.calibrating, ["Building baseline: \(r.baselineDays)/\(params.minBaselineDays) nights with HRV."])
        case .noData:
            return (.noData, ["No overnight HRV or sleeping heart rate for last night."])
        case .low, .medium, .high:
            break
        }
        guard let s = r.score else { return (.noData, ["No recovery score."]) }
        let trendLow = r.flags.contains(.hrvTrendLow)
        let debt = r.flags.contains(.sleepDebt)

        if r.flags.contains(.illnessWatch) {
            return (.rest, ["Sleeping HR and temperature/respiration both elevated (>= +2 SD)."])
        }
        if s <= params.recoverScore {
            return (.recover, ["Recovery well below your typical day."])
        }
        if s <= params.depletedThreshold {
            if trendLow || debt {
                reasons.append(trendLow ? "Low day confirmed by 7-day HRV trend." : "Low day confirmed by sleep debt.")
                return (.recover, reasons)
            }
            return (.maintain, ["Below-typical day without trend confirmation: train as planned, cap intensity."])
        }
        guard s >= params.primedThreshold else { return (.maintain, reasons) }

        // Asymmetric loss: training hard while fatigued costs more than an easy
        // day while fresh, so weak or conflicting evidence demotes "push".
        if r.confidence == .low { return (.maintain, ["Push demoted: low data confidence."]) }
        if trendLow { return (.maintain, ["Push demoted: 7-day HRV trend below normal range."]) }
        if r.flags.contains(.loadSpike) { return (.maintain, ["Push demoted: acute load spike."]) }
        if debt { return (.maintain, ["Push demoted: sleep debt."]) }
        return (.push, reasons)
    }

    func plan(recovery r: Recovery) -> Plan {
        let (action, initialReasons) = directive(for: r)
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
            case .calibrating, .noData: band = nil
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
        return Plan(directive: action, targetLow: low, targetHigh: high, ceiling: ceiling, reasons: reasons)
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

    public func brief(journal: [Day: Set<String>] = [:], historyDays: Int = 14, generatedAt: Date = Date()) -> DailyBrief {
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
                                recoveryScore: recovery(at: k).score,
                                load: l,
                                hrvMs: records[d]?.lnHRV.map(exp),
                                ctl: k < loadPoints.count ? loadPoints[k].ctl : last?.ctl)
        }

        return DailyBrief(
            day: today,
            generatedAt: generatedAt,
            recovery: rec,
            sleep: sleepSummary(at: i),
            load: load,
            plan: plan(recovery: rec),
            history: history,
            tagImpacts: TagAnalysis.impacts(journal: journal, hrvDeviation: hrvDeviations(),
                                            calendar: calendar, params: params),
            hrMaxUsed: hrMax,
            hrRestUsed: hrRest
        )
    }
}
