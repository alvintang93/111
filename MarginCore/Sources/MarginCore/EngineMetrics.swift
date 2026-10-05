import Foundation

/// What the app knows about Health access, so missing data can be explained
/// instead of shown as "–" (or worse, as zero).
public struct HealthAccess: Codable, Sendable, Equatable {
    /// False until the Health permission sheet has been answered.
    public var authorized: Bool
    /// True when the last day-record sync failed (cached values are shown).
    public var lastSyncFailed: Bool

    public init(authorized: Bool = true, lastSyncFailed: Bool = false) {
        self.authorized = authorized
        self.lastSyncFailed = lastSyncFailed
    }
}

extension Engine {
    /// The Margin day whose stored activity window contains `date` (stable
    /// across time-zone changes); the calendar day when no record covers it.
    func dayFor(_ date: Date) -> Day {
        let guess = Day(date, calendar: calendar)
        for d in [guess, guess.adding(-1, calendar: calendar), guess.adding(1, calendar: calendar)] {
            if let w = records[d]?.windows?.activity, date >= w.start && date < w.end { return d }
        }
        return guess
    }

    static let historyDays = 90

    public func healthMetrics(biomarkers: BiomarkerInput?, now: Date, access: HealthAccess = HealthAccess()) -> [MetricReport] {
        let input = biomarkers ?? BiomarkerInput()
        return HealthMetricKind.allCases.map { kind in
            switch kind {
            case .hrv:
                return nightly(kind, \.lnHRV, floor: params.hrvScaleFloor, logSpace: true, access: access, now: now)
            case .sleepingHR:
                return nightly(kind, \.sleepingHR, floor: params.restingHRScaleFloor, logSpace: false, access: access, now: now)
            case .restingHR:
                return nightly(kind, \.appleRestingHR, floor: params.restingHRScaleFloor, logSpace: false, access: access, now: now)
            case .respiratoryRate:
                return nightly(kind, \.respiratoryRate, floor: params.respiratoryScaleFloor, logSpace: false, access: access, now: now)
            case .wristTemperature:
                return nightly(kind, \.wristTemperature, floor: params.temperatureScaleFloor, logSpace: false, access: access, now: now)
            case .sleep:
                return nightly(kind, \.asleepHours, floor: 0.25, logSpace: false, access: access, now: now)
            case .load:
                return loadReport(access: access, now: now)
            case .hrRecovery:
                return recoveryReport(access: access, now: now)
            case .spo2:
                return spo2Report(input, access: access, now: now)
            case .vo2Max:
                return sporadic(kind, .vo2Max, input, access: access, now: now)
            case .bodyMass:
                return sporadic(kind, .bodyMass, input, access: access, now: now)
            case .bodyFat:
                return sporadic(kind, .bodyFat, input, access: access, now: now)
            case .leanMass:
                return sporadic(kind, .leanMass, input, access: access, now: now)
            }
        }
    }

    // MARK: State

    func state(_ kind: HealthMetricKind, current: MetricObservation?, baselineCount: Int?, failed: Bool,
               access: HealthAccess) -> (MetricDataState, String) {
        if !access.authorized && current == nil {
            return (.notAuthorized, "Health permission hasn't been answered yet. Open Margin to grant access.")
        }
        if failed {
            return (.readFailed, current == nil
                    ? "The last Health read for \(kind.title.lowercased()) failed and nothing is saved yet. It retries on the next sync."
                    : "The last Health read failed. Showing the values saved before it.")
        }
        guard let c = current else {
            var why = "No accepted \(kind.title.lowercased()) readings. Health doesn't tell apps whether read access is on, so check Settings → Health → Data Access & Devices → Margin."
            if kind == .spo2 { why += " Blood oxygen isn't recorded on every watch or in every region; no reading is not a result." }
            if kind == .vo2Max { why += " Apple Watch estimates VO₂ max from outdoor walks, runs and hikes with GPS and heart rate." }
            return (.noMeasurement, why)
        }
        if c.day < today.adding(-kind.staleAfterDays, calendar: calendar) {
            return (.stale, "Latest reading is from \(c.day). Newer readings may still arrive from Health.")
        }
        if let n = baselineCount, n < params.minBaselineDays {
            return (.insufficientHistory, "\(n) of \(params.minBaselineDays) days needed for your personal baseline.")
        }
        return (.available, "")
    }

    // MARK: Nightly / daily record metrics

    func nightly(_ kind: HealthMetricKind, _ key: KeyPath<DayRecord, Double?>, floor: Double, logSpace: Bool,
                 access: HealthAccess, now: Date) -> MetricReport {
        func display(_ x: Double) -> Double { logSpace ? exp(x) : x }
        func dateOf(_ r: DayRecord) -> Date {
            kind == .restingHR ? r.day.date(hour: 12, calendar: calendar) : (r.sleep?.mainWake ?? r.day.date(hour: 7, calendar: calendar))
        }
        let window = days.suffix(Self.historyDays)
        let history: [MetricObservation] = window.compactMap { d in
            guard let r = records[d], let x = r[keyPath: key] else { return nil }
            var count: Int?
            var source: String?
            switch kind {
            case .hrv:
                count = r.hrvSampleCount
                source = Array(Set(r.hrvReadings.filter(\.usedByScore).compactMap(\.source))).sorted().joined(separator: ", ")
            case .sleepingHR: count = r.sleepingHRSampleCount
            case .respiratoryRate: count = r.respiratorySampleCount
            default: break
            }
            let note = excluded.contains(d) ? "Marked status: left out of baselines" : nil
            return MetricObservation(date: dateOf(r), day: d, value: display(x), source: source?.isEmpty == false ? source : nil,
                                     count: count, note: note)
        }
        let current = history.last
        var baseline: MetricBaseline?
        var delta: Double?, deltaPct: Double?, z: Double?
        var baselineCount: Int?
        if let c = current, let i = days.firstIndex(of: c.day) {
            let values = baselineValues(key, before: i)
            baselineCount = values.count
            if let b = RobustBaseline(values: values, minCount: params.minBaselineDays, scaleFloor: floor),
               let x = records[c.day]?[keyPath: key] {
                baseline = MetricBaseline(center: display(b.center), scale: b.scale, count: b.count, windowDays: params.baselineWindowDays,
                                          method: "Median and robust SD (1.4826 × MAD) of the previous \(params.baselineWindowDays) days, excluding marked days" + (logSpace ? ", in ln ms" : ""))
                z = b.z(x)
                delta = display(x) - display(b.center)
                if logSpace { deltaPct = (exp(x - b.center) - 1) * 100 }
            }
        }
        var readings: [MetricObservation] = []
        if kind == .hrv, let c = current, let r = records[c.day] {
            readings = r.hrvReadings.map {
                MetricObservation(date: $0.date, day: c.day, value: $0.sdnnMs, source: $0.source,
                                  note: $0.usedByScore ? "Used by recovery (overnight window)" : "Not used by recovery (outside the overnight window)")
            }
        }
        let (st, detail) = state(kind, current: current, baselineCount: baselineCount, failed: access.lastSyncFailed, access: access)
        var notes: [String] = []
        if kind.usedByRecovery, current?.day == today {
            notes.append("This is the value and baseline today's recovery score uses.")
        }
        if kind == .hrv, let r = current.flatMap({ records[$0.day] }), !r.hrvDuringSleep {
            notes.append("No HRV during recorded sleep: the 20:00–10:00 fallback window was used.")
        }
        return MetricReport(kind: kind, state: st, stateDetail: detail, current: current,
                            previous: history.count >= 2 ? history[history.count - 2] : nil,
                            baseline: baseline, deltaFromBaseline: delta, deltaPercent: deltaPct, z: z,
                            trends: MetricMath.trends(history, windows: kind.trendWindows, asOf: now, sporadic: false),
                            history: history, readings: readings,
                            sources: Array(Set(history.compactMap(\.source).flatMap { $0.components(separatedBy: ", ") })).sorted(),
                            notes: notes, methodology: Self.methodology(kind))
    }

    // MARK: Load and HR recovery

    func loadReport(access: HealthAccess, now: Date) -> MetricReport {
        let window = days.indices.suffix(Self.historyDays)
        let history: [MetricObservation] = window.compactMap { k in
            guard let r = records[days[k]], r.coverageHours >= params.minCoverageHours, let l = trimp(r) else { return nil }
            return MetricObservation(date: activityWindow(at: k).end.addingTimeInterval(-1), day: days[k], value: l,
                                     note: k == todayIndex ? "So far today" : nil)
        }
        var baseline: MetricBaseline?
        if let lp = eligibleCTL(throughIndex: loadPoints.count - 1) {
            baseline = MetricBaseline(center: lp.ctl, scale: 0, count: loadPoints.count, windowDays: Int(params.ctlDays),
                                      method: "Chronic training load (CTL): 42-day exponential average of daily TRIMP")
        }
        let current = history.last
        let (st, detail) = state(.load, current: current, baselineCount: nil, failed: access.lastSyncFailed, access: access)
        return MetricReport(kind: .load, state: st, stateDetail: detail, current: current,
                            previous: history.count >= 2 ? history[history.count - 2] : nil, baseline: baseline,
                            deltaFromBaseline: zip2(current?.value, baseline?.center).map { $0.0 - $0.1 }, deltaPercent: nil, z: nil,
                            trends: MetricMath.trends(history, windows: HealthMetricKind.load.trendWindows, asOf: now, sporadic: false),
                            history: history, readings: [], sources: [], notes: [], methodology: Self.methodology(.load))
    }

    func recoveryReport(access: HealthAccess, now: Date) -> MetricReport {
        let history: [MetricObservation] = days.suffix(Self.historyDays).flatMap { d in
            (records[d]?.workoutDetails ?? []).compactMap { w in
                w.recovery1.map {
                    MetricObservation(date: w.end, day: d, value: $0, source: w.source,
                                      note: "\(WorkoutType.name(w.activityType)) · \(w.appleRecovery1 != nil ? "Apple's value" : "Margin's 60 s drop")")
                }
            }
        }
        let current = history.last
        let prior = history.dropLast().filter { $0.date >= now.addingTimeInterval(-Double(params.heartRateRecoveryBaselineDays) * 86400) }.map(\.value)
        var baseline: MetricBaseline?
        if prior.count >= 3, let m = Stats.median(prior) {
            baseline = MetricBaseline(center: m, scale: 1.4826 * (Stats.mad(prior) ?? 0), count: prior.count,
                                      windowDays: params.heartRateRecoveryBaselineDays,
                                      method: "Median of earlier workouts in the last \(params.heartRateRecoveryBaselineDays) days (needs 3)")
        }
        let (st0, detail0) = state(.hrRecovery, current: current, baselineCount: nil, failed: access.lastSyncFailed, access: access)
        var st = st0, detail = detail0
        if st == .available && baseline == nil {
            st = .insufficientHistory
            detail = "\(prior.count) of 3 earlier workouts needed for a typical value."
        }
        return MetricReport(kind: .hrRecovery, state: st, stateDetail: detail, current: current,
                            previous: history.count >= 2 ? history[history.count - 2] : nil, baseline: baseline,
                            deltaFromBaseline: zip2(current?.value, baseline?.center).map { $0.0 - $0.1 }, deltaPercent: nil, z: nil,
                            trends: MetricMath.trends(history, windows: [30, 60], asOf: now, sporadic: true),
                            history: history, readings: [], sources: Array(Set(history.compactMap(\.source))).sorted(),
                            notes: [], methodology: Self.methodology(.hrRecovery))
    }

    // MARK: Biomarker metrics

    func spo2Report(_ input: BiomarkerInput, access: HealthAccess, now: Date) -> MetricReport {
        let samples = input.clean(.spo2, asOf: now).samples
        var byDay: [Day: [TimedValue]] = [:]
        for s in samples { byDay[dayFor(s.start), default: []].append(s) }
        func overnight(_ s: TimedValue, _ d: Day) -> Bool {
            guard let n = records[d]?.sleep else { return false }
            return s.start >= n.mainOnset && s.start <= n.mainWake
        }
        // Daily median: one SpO2 reading is noisy, and daily medians make days comparable.
        let history: [MetricObservation] = byDay.keys.sorted().suffix(Self.historyDays).compactMap { d in
            let xs = byDay[d]!
            guard let m = Stats.median(xs.map(\.value)) else { return nil }
            let night = xs.filter { overnight($0, d) }.count
            return MetricObservation(date: xs.map(\.start).max()!, day: d, value: m,
                                     source: Array(Set(xs.compactMap(\.source))).sorted().joined(separator: ", "),
                                     count: xs.count, note: night > 0 ? "\(night) overnight reading(s)" : nil)
        }
        let latest = samples.last.map { s -> MetricObservation in
            let d = dayFor(s.start)
            return MetricObservation(date: s.start, day: d, value: s.value, source: s.source, note: overnight(s, d) ? "Overnight" : nil)
        }
        var baseline: MetricBaseline?
        var baselineCount: Int?
        if let lastDay = history.last?.day {
            let prior = history.filter { $0.day < lastDay && $0.day >= lastDay.adding(-params.baselineWindowDays, calendar: calendar) }.map(\.value)
            baselineCount = prior.count
            if let b = RobustBaseline(values: prior, minCount: params.minBaselineDays, scaleFloor: 0.5) {
                baseline = MetricBaseline(center: b.center, scale: b.scale, count: b.count, windowDays: params.baselineWindowDays,
                                          method: "Median and robust SD of the previous \(params.baselineWindowDays) days' daily medians")
            }
        }
        let readings: [MetricObservation] = (history.last.flatMap { byDay[$0.day] } ?? []).map {
            MetricObservation(date: $0.start, day: history.last!.day, value: $0.value, source: $0.source,
                              note: overnight($0, history.last!.day) ? "Overnight" : "Daytime")
        }
        let (st, detail) = state(.spo2, current: latest, baselineCount: baselineCount, failed: input.didFail(.spo2), access: access)
        let today = history.last
        return MetricReport(kind: .spo2, state: st, stateDetail: detail, current: latest, previous: history.count >= 2 ? history[history.count - 2] : nil,
                            baseline: baseline, deltaFromBaseline: zip2(today?.value, baseline?.center).map { $0.0 - $0.1 }, deltaPercent: nil,
                            z: zip2(today?.value, baseline).map { ($0.0 - $0.1.center) / max($0.1.scale, 0.5) },
                            trends: MetricMath.trends(history, windows: HealthMetricKind.spo2.trendWindows, asOf: now, sporadic: false),
                            history: history, readings: readings, sources: Array(Set(samples.compactMap(\.source))).sorted(),
                            notes: ["Blood oxygen is shown for context. It is not a recovery input, and Margin doesn't interpret it."],
                            methodology: Self.methodology(.spo2))
    }

    func sporadic(_ kind: HealthMetricKind, _ b: BiomarkerKind, _ input: BiomarkerInput, access: HealthAccess, now: Date) -> MetricReport {
        let (samples, stats) = input.clean(b, asOf: now)
        let all = samples.map { MetricObservation(date: $0.start, day: dayFor($0.start), value: $0.value, source: $0.source) }
        let history = TrendModel.thin(all.map { TimedValue(start: $0.date, end: $0.date, value: $0.value, source: $0.source) }, to: 120)
            .map { MetricObservation(date: $0.start, day: dayFor($0.start), value: $0.value, source: $0.source) }
        let current = all.last
        let previous = all.count >= 2 ? all[all.count - 2] : nil
        let (st, detail) = state(kind, current: current, baselineCount: nil, failed: input.didFail(b), access: access)
        var notes: [String] = []
        if stats.rejected > 0 {
            notes.append("\(stats.implausible) implausible, \(stats.duplicates) duplicate and \(stats.future) future-dated reading(s) were left out.")
        }
        if kind == .vo2Max { notes.append("Apple's estimate from Health. Margin doesn't estimate VO₂ max itself.") }
        return MetricReport(kind: kind, state: st, stateDetail: detail, current: current, previous: previous, baseline: nil,
                            deltaFromBaseline: nil, deltaPercent: nil, z: nil,
                            trends: MetricMath.trends(all, windows: kind.trendWindows, asOf: now, sporadic: true),
                            history: history, readings: [], sources: Array(Set(samples.compactMap(\.source))).sorted(),
                            notes: notes, methodology: Self.methodology(kind))
    }

    static func methodology(_ kind: HealthMetricKind) -> String {
        switch kind {
        case .hrv:
            return "Overnight HRV is the geometric mean of Apple Watch SDNN readings taken during your main sleep bout (or 20:00–10:00 when no sleep was recorded), attributed to the day you wake. Daytime readings, such as Mindfulness sessions, are listed but never mixed in. The recovery score compares ln(HRV) with your 60-day median."
        case .sleepingHR:
            return "The 10th percentile of heart rate during your main sleep bout (needs at least 10 readings). This is the heart-rate input to recovery."
        case .restingHR:
            return "Apple's daily resting heart rate, averaged per day. Margin uses it as HRrest for training load and zones, not as a recovery input."
        case .respiratoryRate:
            return "Mean of the respiratory-rate readings Apple Watch records during sleep (same window as HRV). Recovery penalises it only above +1 robust SD of your baseline."
        case .wristTemperature:
            return "Apple's sleeping wrist temperature for the night. Recovery penalises it only above +1 robust SD. Cycle phase can shift it by a few tenths of a degree."
        case .spo2:
            return "Blood oxygen readings from Health, converted from a fraction to percent. Values outside 50–100 % are rejected. Shown as the daily median, with each reading tagged overnight or daytime."
        case .sleep:
            return "Time asleep in the night window (18:00 to 18:00) from the highest-priority source (Apple Watch first), including naps."
        case .vo2Max:
            return "Apple's VO₂ max estimate (cardio fitness) as stored in Health. Values outside 10–90 mL/kg/min are rejected. Trends use Theil–Sen slopes and need at least 3 readings."
        case .bodyMass, .bodyFat, .leanMass:
            return "Readings from Health (scales or manual entries). Implausible values are rejected, not clamped. Change compares the latest reading with the reading nearest the start of each window."
        case .hrRecovery:
            return "Heart-rate drop in the first minute after each workout: Apple's value when Health has one, else Margin's measurement from the heart-rate samples after the workout ended."
        case .load:
            return "Banister TRIMP from time at heart rate, per day. The baseline is your chronic load (CTL)."
        }
    }
}

private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

extension DayRecord {
    /// Time asleep in hours (for the sleep metric report).
    public var asleepHours: Double? { sleep.map { $0.asleep / 3600 } }
}
