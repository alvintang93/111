import Charts
import SwiftUI
import MarginCore

// MARK: - Body page (biomarkers)

struct BodyView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let b = model.brief, b.isCurrent(), let bio = b.biomarkers {
                    if let age = bio.biologicalAge {
                        BiologicalAgeCard(estimate: age)
                    } else if model.settings.age == nil {
                        Text("Biological age needs your date of birth in Health.").font(.footnote)
                    }
                    if let v = bio.vo2Max {
                        TrendSection(title: "VO2 max", unit: "mL/kg/min", trend: v, digits: 1, higherIsBetter: true)
                    }
                    if let r = bio.restingHR {
                        TrendSection(title: "Resting HR", unit: "bpm", trend: r, digits: 0, higherIsBetter: false)
                    }
                    if let m = bio.bodyMass {
                        TrendSection(title: "Body mass", unit: "kg", trend: m, digits: 1, higherIsBetter: nil)
                    }
                    if let f = bio.bodyFat {
                        TrendSection(title: "Body fat", unit: "%", trend: f, digits: 1, higherIsBetter: false)
                    }
                    if let l = bio.leanMass {
                        TrendSection(title: "Lean mass", unit: "kg", trend: l, digits: 1, higherIsBetter: true)
                    }
                    if let bp = bio.bloodPressure { BloodPressureSection(bp: bp) }
                    if let g = bio.glucose { GlucoseSection(glucose: g) }
                    if let n = bio.nutrition { NutritionSection(nutrition: n) }
                    if bio.vo2Max == nil && bio.bodyMass == nil && bio.bloodPressure == nil && bio.nutrition == nil {
                        Text("Nothing here yet. VO2 max comes from outdoor walks and runs. Body composition, blood pressure, glucose and food come from apps or devices that write them to Health.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let at = bio.fetchedAt {
                        Text("Read from Health \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Body")
    }
}

struct BiologicalAgeCard: View {
    let estimate: BiologicalAgeEstimate

    var body: some View {
        card.padding(8).glassCard(cornerRadius: 16, tint: .teal)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f", estimate.estimate)).font(.system(size: 36, weight: .bold, design: .rounded))
                Text("BIOLOGICAL AGE").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                let delta = estimate.estimate - Double(estimate.chronological)
                Text(String(format: "%+.1f y", delta)).font(.footnote).foregroundStyle(delta <= 0 ? .green : .orange)
            }
            ForEach(estimate.components) { c in
                VStack(alignment: .leading, spacing: 0) {
                    MetricRow(label: c.name, value: String(format: "%+.1f y", c.years), tint: c.years <= 0 ? .green : .orange)
                    Text(c.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text("An estimate from cardio fitness, resting HR and sleep, compared with age norms. Not a clinical age.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Readings with a robust trend and a 30-day projection band.
struct TrendSection: View {
    let title: String
    let unit: String
    let trend: Trend
    let digits: Int
    /// Colours the slope: nil = neutral.
    let higherIsBetter: Bool?

    var body: some View {
        card.padding(8).glassCard(cornerRadius: 16)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(text: title)
            HStack(alignment: .firstTextBaseline) {
                Text(fmt(trend.latest)).font(.title3.bold()).monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let s = trend.slopePerWeek {
                    Text(String(format: "%+.\(digits == 0 ? 1 : digits)f/wk", s)).font(.footnote).foregroundStyle(slopeColor(s))
                }
            }
            Chart {
                ForEach(trend.points, id: \.start) { p in
                    PointMark(x: .value("Date", p.start), y: .value(title, p.value)).symbolSize(10).foregroundStyle(.white)
                }
                if let proj = trend.projected30, let lo = trend.projectedLow, let hi = trend.projectedHigh {
                    let end = trend.latestDate.addingTimeInterval(30 * 86400)
                    LineMark(x: .value("Date", trend.latestDate), y: .value(title, trend.latest))
                        .foregroundStyle(Color.yellow).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    LineMark(x: .value("Date", end), y: .value(title, proj))
                        .foregroundStyle(Color.yellow).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    RuleMark(x: .value("Date", end), yStart: .value("low", lo), yEnd: .value("high", hi))
                        .foregroundStyle(Color.yellow.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 4))
                }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 60)
            if let proj = trend.projected30, let lo = trend.projectedLow, let hi = trend.projectedHigh {
                Text("In 30 days: \(fmt(proj)) (\(fmt(lo))–\(fmt(hi))) if the current trend holds.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("\(trend.count) reading(s). A trend needs 4 readings over at least 14 days.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.\(digits)f", v) }

    private func slopeColor(_ s: Double) -> Color {
        guard let better = higherIsBetter, abs(s) > 1e-9 else { return .secondary }
        return (s > 0) == better ? .green : .orange
    }
}

struct BloodPressureSection: View {
    let bp: BloodPressureSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(text: "Blood pressure")
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f/%.0f", bp.latestSystolic, bp.latestDiastolic)).font(.title3.bold()).monospacedDigit()
                Text("mmHg").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(bp.category.title).font(.footnote).foregroundStyle(bp.category.color)
            }
            Text(bp.latestDate.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            if let s = bp.averageSystolic30d, let d = bp.averageDiastolic30d {
                MetricRow(label: "30-day average (\(bp.readings30d))", value: String(format: "%.0f/%.0f", s, d))
            }
            if let s = bp.systolic?.slopePerWeek {
                MetricRow(label: "Systolic trend", value: String(format: "%+.1f/wk", s))
            }
            Text("Reading categories from the American Heart Association. One reading is not an assessment; talk to a clinician about your blood pressure.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct GlucoseSection: View {
    let glucose: GlucoseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(text: "Glucose")
            MetricRow(label: "Latest", value: String(format: "%.0f mg/dL", glucose.latest))
            if let m = glucose.mean24h { MetricRow(label: "24 h mean (\(glucose.readings24h))", value: String(format: "%.0f", m)) }
            if let r = glucose.inRange24h { MetricRow(label: "24 h in 70–140", value: String(format: "%.0f%%", r * 100)) }
            if glucose.dailyMeans.count >= 2 {
                Chart(glucose.dailyMeans) { d in
                    LineMark(x: .value("Day", d.day.description), y: .value("mg/dL", d.value)).foregroundStyle(.purple)
                }
                .chartXAxis(.hidden)
                .frame(height: 50)
            }
        }
    }
}

struct NutritionSection: View {
    let nutrition: NutritionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(text: "Food (from Health)")
            if let t = nutrition.today {
                MetricRow(label: "Today", value: t.energyKcal.map { String(format: "%.0f kcal", $0) } ?? "–")
                MetricRow(label: "Protein / carbs / fat", value: macro(t))
            }
            if let a = nutrition.average7 {
                MetricRow(label: "7-day avg (\(nutrition.loggedDays7) d)", value: a.energyKcal.map { String(format: "%.0f kcal", $0) } ?? "–")
                MetricRow(label: "Macros avg", value: macro(a))
            }
            if let p = nutrition.proteinPerKg7 {
                MetricRow(label: "Protein per kg", value: String(format: "%.1f g", p))
            }
            Text("Logged in a food app that writes to Health. Days with nothing logged are skipped.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func macro(_ n: NutritionDay) -> String {
        func g(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "–" }
        return "\(g(n.proteinG)) / \(g(n.carbsG)) / \(g(n.fatG)) g"
    }
}

// MARK: - Running form

struct RunningView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if let r = model.brief?.biomarkers?.running {
                Section("Latest run · \(r.latest.start.formatted(date: .abbreviated, time: .omitted))") {
                    row("Pace", r.latest.pace.map(paceText), r.typical?.pace.map(paceText))
                    row("Cadence", r.latest.cadence.map { String(format: "%.0f spm", $0) }, r.typical?.cadence.map { String(format: "%.0f", $0) })
                    row("Stride", r.latest.strideLengthM.map { String(format: "%.2f m", $0) }, r.typical?.strideLengthM.map { String(format: "%.2f", $0) })
                    row("Vertical oscillation", r.latest.verticalOscillationCm.map { String(format: "%.1f cm", $0) },
                        r.typical?.verticalOscillationCm.map { String(format: "%.1f", $0) })
                    row("Ground contact", r.latest.groundContactMs.map { String(format: "%.0f ms", $0) },
                        r.typical?.groundContactMs.map { String(format: "%.0f", $0) })
                    row("Power", r.latest.powerW.map { String(format: "%.0f W", $0) }, r.typical?.powerW.map { String(format: "%.0f", $0) })
                    if let d = r.latest.distanceKm { MetricRow(label: "Distance", value: String(format: "%.2f km", d)) }
                }
                if r.recent.count >= 2 {
                    Section("Cadence, last \(r.recent.count) runs") {
                        Chart(r.recent.filter { $0.cadence != nil }) { run in
                            LineMark(x: .value("Run", run.start), y: .value("spm", run.cadence ?? 0)).foregroundStyle(.orange)
                            PointMark(x: .value("Run", run.start), y: .value("spm", run.cadence ?? 0)).foregroundStyle(.orange).symbolSize(10)
                        }
                        .chartXAxis(.hidden)
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 60)
                    }
                }
                Text("Grey values are your median over the other \(r.runs - 1) run(s) in 60 days. Form metrics need an outdoor or treadmill run recorded with the Workout app.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No runs in the last 60 days. Record a run with the Workout app to see cadence, stride, vertical oscillation, ground contact time and power.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Running form")
    }

    private func row(_ label: String, _ value: String?, _ typical: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "–").monospacedDigit()
            if let t = typical { Text(t).foregroundStyle(.gray).monospacedDigit() }
        }
        .font(.footnote)
    }

    private func paceText(_ minutesPerKm: Double) -> String {
        let total = Int((minutesPerKm * 60).rounded())
        return String(format: "%d:%02d /km", total / 60, total % 60)
    }
}

// MARK: - Cycle

struct CycleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if let c = model.brief?.biomarkers?.cycle {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Day \(c.cycleDay)").font(.title3.bold())
                        Spacer()
                        Text(c.phase.title).foregroundStyle(c.phase.color)
                    }
                    MetricRow(label: "Next period (predicted)", value: c.predictedNextStart.description)
                    MetricRow(label: "Typical length", value: c.medianLength.map { "\($0) days (\(c.cyclesUsed) cycles)" } ?? "28 days (default)")
                }
                Section("By phase") {
                    ForEach(c.byPhase) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.phase.title).font(.footnote.weight(.semibold)).foregroundStyle(p.phase.color)
                            HStack {
                                Text(p.hrvDeltaPercent.map { String(format: "HRV %+.0f%%", $0) } ?? "HRV –")
                                Spacer()
                                Text(p.temperatureDelta.map { String(format: "Temp %+.2f °C", $0) } ?? "Temp –")
                            }
                            .font(.caption2).monospacedDigit()
                            Text("\(p.nights) night(s)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Phases are estimated from period starts logged in Health, with ovulation placed 14 days before the next period. Wrist temperature usually rises a few tenths of a degree in the luteal phase; Margin's recovery score only counts temperature beyond your usual range.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Log periods in the Health or Cycle Tracking app to see your phase, predictions, and HRV and temperature by phase.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Cycle")
    }
}

// MARK: - Compare two metrics

struct CompareView: View {
    @EnvironmentObject private var model: AppModel
    @State private var a: CompareMetric = .caffeine
    @State private var b: CompareMetric = .hrv
    @State private var nextDay = true

    var body: some View {
        List {
            Picker("First", selection: $a) { ForEach(CompareMetric.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Second", selection: $b) { ForEach(CompareMetric.allCases, id: \.self) { Text($0.title).tag($0) } }
            Toggle("Second = next day", isOn: $nextDay)
            if let series = model.brief?.series,
               let sa = series.first(where: { $0.metric == a }), let sb = series.first(where: { $0.metric == b }) {
                let pairs = Correlation.pairs(sa, sb, lagDays: nextDay ? 1 : 0, calendar: .current)
                if pairs.count >= 3 {
                    Chart {
                        ForEach(normalised(pairs.map(\.x)).enumerated().map { $0 }, id: \.offset) { k, v in
                            LineMark(x: .value("Day", pairs[k].day.description), y: .value("z", v), series: .value("Metric", a.title))
                                .foregroundStyle(.yellow)
                        }
                        ForEach(normalised(pairs.map(\.y)).enumerated().map { $0 }, id: \.offset) { k, v in
                            LineMark(x: .value("Day", pairs[k].day.description), y: .value("z", v), series: .value("Metric", b.title))
                                .foregroundStyle(.cyan)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 80)
                    HStack {
                        Text(a.title).foregroundStyle(.yellow)
                        Text("vs").foregroundStyle(.secondary)
                        Text(b.title + (nextDay ? " (next day)" : "")).foregroundStyle(.cyan)
                    }
                    .font(.caption2)
                    if let r = Correlation.spearman(pairs.map(\.x), pairs.map(\.y)) {
                        MetricRow(label: "Spearman ρ", value: String(format: "%+.2f", r.rho))
                        MetricRow(label: "Days paired", value: "\(r.n)")
                        if let p = r.pValue {
                            MetricRow(label: "p", value: String(format: "%.3f", p), tint: p < 0.05 ? .green : .secondary)
                        }
                    }
                    Text("Both lines are scaled to their own range over the last 30 days. A correlation is an association in your data, not a cause.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Fewer than 3 days with both values. Caffeine and water count only on days you logged them.").font(.footnote)
                }
            }
        }
        .navigationTitle("Compare")
    }

    private func normalised(_ xs: [Double]) -> [Double] {
        guard let lo = xs.min(), let hi = xs.max(), hi > lo else { return xs.map { _ in 0.5 } }
        return xs.map { ($0 - lo) / (hi - lo) }
    }
}

// MARK: - Load page: cardio focus

struct CardioFocusSection: View {
    let summary: CardioFocusSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let total = max(summary.minutes28d.reduce(0, +), 1)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(CardioFocus.allCases, id: \.self) { f in
                        Rectangle().fill(f.color).frame(width: geo.size.width * summary.minutes28d[f.index] / total)
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                ForEach(CardioFocus.allCases, id: \.self) { f in
                    Text("\(f.short) \(Int(summary.minutes28d[f.index].rounded()))").font(.system(size: 10)).foregroundStyle(f.color)
                }
            }
            ForEach(summary.workouts.suffix(3).reversed()) { w in
                MetricRow(label: "\(WorkoutType.name(w.activityType)) \(w.start.formatted(.dateTime.weekday(.abbreviated)))",
                          value: w.focus?.title ?? "–", tint: w.focus?.color ?? .secondary)
            }
            Text("Workout minutes over 28 days in zones 1–2 (low aerobic), 3–4 (high aerobic) and 5 (anaerobic). Zones start at \(summary.bounds.map { "\(Int($0.rounded()))" }.joined(separator: " / ")) bpm.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings: zones and smart alarm

struct ZonesSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Picker("Zones from", selection: Binding(
                get: { model.lifestyle.zones.mode },
                set: { model.lifestyle.zones = ZoneSettings.defaults(for: $0) }
            )) {
                Text("% HR reserve").tag(ZoneMode.reserve)
                Text("% HRmax").tag(ZoneMode.maxHR)
                Text("bpm").tag(ZoneMode.bpm)
            }
            ForEach(0..<5, id: \.self) { k in
                Stepper(label(k), value: Binding(
                    get: { model.lifestyle.zones.lowerBounds[k] },
                    set: { v in
                        var z = model.lifestyle.zones
                        z.lowerBounds[k] = v
                        if z.isValid { model.lifestyle.zones = z }
                    }
                ), in: range(k), step: model.lifestyle.zones.mode == .bpm ? 1 : 1)
            }
            if let b = model.brief {
                let bpm = model.lifestyle.zones.bpmBounds(hrRest: b.hrRestUsed, hrMax: b.hrMaxUsed)
                Text("In bpm: \(bpm.map { "\(Int($0.rounded()))" }.joined(separator: " / ")) (HRrest \(Int(b.hrRestUsed.rounded())), HRmax \(Int(b.hrMaxUsed)))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("Reset to defaults") { model.lifestyle.zones = .standard }
        }
        .navigationTitle("HR zones")
    }

    private func label(_ k: Int) -> String {
        let v = Int(model.lifestyle.zones.lowerBounds[k].rounded())
        return model.lifestyle.zones.mode == .bpm ? "Zone \(k + 1) from \(v) bpm" : "Zone \(k + 1) from \(v)%"
    }

    private func range(_ k: Int) -> ClosedRange<Double> {
        model.lifestyle.zones.mode == .bpm ? 60...220 : 30...100
    }
}

struct SmartAlarmSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var alarm: SmartAlarmManager

    var body: some View {
        List {
            Toggle("Smart alarm", isOn: $model.lifestyle.smartAlarm.enabled)
            Stepper(String(format: "Wake by %02d:%02d", model.lifestyle.smartAlarm.wakeMinutes / 60, model.lifestyle.smartAlarm.wakeMinutes % 60),
                    value: $model.lifestyle.smartAlarm.wakeMinutes, in: 4 * 60...11 * 60, step: 5)
            Stepper("Window \(model.lifestyle.smartAlarm.windowMinutes) min", value: $model.lifestyle.smartAlarm.windowMinutes, in: 10...30, step: 5)
            if let w = alarm.scheduledWake {
                Text("Armed for \(w.formatted(date: .abbreviated, time: .shortened)).").font(.footnote).foregroundStyle(.green)
            } else if model.lifestyle.smartAlarm.enabled {
                Text("Not armed yet. Open Margin in the evening to arm it.").font(.footnote).foregroundStyle(.orange)
            }
            if let last = alarm.lastAlarm { Text(last).font(.caption2).foregroundStyle(.secondary) }
            Text("Margin wakes you with haptics at the first sustained wrist movement in the window (a sign of lighter sleep), or at the wake time. watchOS only lets an app arm the alarm while it is open, so open Margin before bed. It doesn't replace a backup alarm.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .navigationTitle("Smart alarm")
    }
}
