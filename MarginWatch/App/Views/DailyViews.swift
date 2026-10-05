import Charts
import SwiftUI
import MarginCore

// MARK: - Today additions

/// The pinned metrics, two per row. Tapping a tile opens its detail.
struct TileGrid: View {
    @EnvironmentObject private var model: AppModel
    let brief: DailyBrief

    var body: some View {
        let metrics = model.lifestyle.pinnedMetrics
        GlassGroup(spacing: 6) {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(metrics, id: \.self) { m in
                NavigationLink {
                    destination(for: m)
                } label: {
                    TileView(tile: m == .topLift || m == .muscles
                             ? DashboardTile.makeStrength(m, brief: brief, now: Date(), calendar: .current, unit: model.lifestyle.weightUnit)
                             : DashboardTile.make(m, brief: brief, now: Date(), calendar: .current))
                }
                .buttonStyle(.plain)
            }
        }
        }
    }

    @ViewBuilder
    private func destination(for m: DashboardMetric) -> some View {
        switch m {
        case .energy, .stress: EnergyView()
        case .strain, .hrRecovery: LoadView()
        case .sleep: SleepView()
        case .caffeine, .water: IntakeView()
        case .recovery, .hrv, .sleepingHR: DriversView()
        case .topLift, .muscles: StrengthHomeView()
        }
    }
}

struct TileView: View {
    let tile: DashboardTile

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tile.metric.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(tile.value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tile.tone.color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let f = tile.fraction {
                Gauge(value: f) { EmptyView() }
                    .gaugeStyle(.accessoryLinear)
                    .tint(tile.tone.color)
            }
            Text(tile.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14, tint: tile.tone == .neutral ? nil : tile.tone.color)
        .accessibilityElement(children: .combine)
    }
}

/// One-tap logging from Today.
struct QuickLogRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GlassGroup(spacing: 6) {
        HStack(spacing: 6) {
            Button {
                model.addIntake(.caffeine, amount: model.lifestyle.typicalDoseMg, label: "Coffee")
            } label: {
                Label("Coffee", systemImage: "cup.and.saucer.fill").labelStyle(.iconOnly)
            }
            .tint(.brown)
            .glassButton()
            .accessibilityLabel("Log a coffee")
            Button {
                model.addIntake(.water, amount: 250)
            } label: {
                Label("Water", systemImage: "drop.fill").labelStyle(.iconOnly)
            }
            .tint(.cyan)
            .glassButton()
            .accessibilityLabel("Log 250 millilitres of water")
            NavigationLink {
                DayTimelineView()
            } label: {
                Label("Timeline", systemImage: "list.bullet.rectangle").labelStyle(.iconOnly)
            }
            .glassButton()
            .accessibilityLabel("Timeline")
        }
        }
    }
}

struct StatusBanner: View {
    let statuses: [StatusKind]

    var body: some View {
        if let s = statuses.first {
            NavigationLink {
                StatusView()
            } label: {
                Label("Marked \(s.title.lowercased()) · baselines paused", systemImage: s.symbol)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCapsule(tint: .orange)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Energy and stress page

struct EnergyView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let b = model.brief, b.isCurrent() {
                    if let e = b.energy {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(e.current)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                            Text("ENERGY").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("from \(e.start)").font(.footnote).foregroundStyle(.secondary)
                        }
                        Chart(e.points) { p in
                            AreaMark(x: .value("Time", p.date), y: .value("Energy", p.level))
                                .foregroundStyle(Color.yellow.opacity(0.3))
                            LineMark(x: .value("Time", p.date), y: .value("Energy", p.level))
                                .foregroundStyle(.yellow)
                        }
                        .chartYScale(domain: 0...100)
                        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                        .frame(height: 70)
                        MetricRow(label: "Drained by load", value: String(format: "−%.0f", e.drainedByStrain))
                        MetricRow(label: "Drained by stress", value: String(format: "−%.0f", e.drainedByStress))
                        MetricRow(label: "Drained by time awake", value: String(format: "−%.0f", e.drainedByWaking))
                        MetricRow(label: "Charged by calm rest", value: String(format: "+%.0f", e.chargedByRest))
                        if e.chargedByNaps > 0 {
                            MetricRow(label: "Charged by naps", value: String(format: "+%.0f", e.chargedByNaps))
                        }
                        Text(e.startSource.explanation).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Energy starts once you're awake and last night's sleep is recorded.").font(.footnote)
                    }
                    SectionHeader(text: "Stress")
                    if let s = b.stress {
                        StressSection(stress: s)
                    }
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Energy")
    }
}

struct StressSection: View {
    let stress: StressSummary

    var body: some View {
        card.padding(8).glassCard(cornerRadius: 16)
    }

    private var card: some View {
        VStack(spacing: 6) {
            HStack {
                Text(stress.current.map { "\($0)" } ?? "–").font(.title3.bold()).monospacedDigit()
                Text(stress.current.map { StressBand(level: $0).title } ?? "no recent rest data")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text("day \(stress.score.map { "\($0)" } ?? "–")").font(.footnote).monospacedDigit()
            }
            Chart(stress.hours.filter { $0.level != nil }) { h in
                BarMark(x: .value("Hour", h.start, unit: .hour), y: .value("Stress", h.level ?? 0))
                    .foregroundStyle(StressBand(level: h.level ?? 0).color)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 60)
            HStack(spacing: 4) {
                ForEach(Array(StressBand.allCases.enumerated()), id: \.offset) { k, band in
                    VStack(spacing: 1) {
                        Text("\(Int(stress.bandMinutes[k].rounded()))").font(.caption2).monospacedDigit()
                        Rectangle().fill(band.color).frame(height: 3)
                        Text(band.title).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Minutes of rest-state heart rate by level. Measured while still and awake, outside workouts, against your resting HR of \(Int(stress.referenceHR.rounded())) bpm.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Load page additions

struct StrainCard: View {
    let strain: StrainSummary

    var body: some View {
        card.padding(8).glassCard(cornerRadius: 16, tint: .orange)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(strain.score.map { "\($0)" } ?? "–").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text("STRAIN").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let lo = strain.targetLow, let hi = strain.targetHigh {
                    Text("target \(lo)–\(hi)").font(.footnote).foregroundStyle(.green)
                }
            }
            if !strain.hourly.isEmpty {
                Chart(strain.hourly) { h in
                    BarMark(x: .value("Hour", h.start, unit: .hour), y: .value("Load", h.value))
                        .foregroundStyle(Color.orange.opacity(0.8))
                }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 50)
            }
            Text(strain.reference == .chronicLoad
                 ? "50 = your typical day (CTL \(Fmt.load(strain.referenceLoad)))."
                 : "Provisional: 50 = load \(Fmt.load(strain.referenceLoad)) until 28 days of load history.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct HeartRateRecoverySection: View {
    let summary: HeartRateRecoverySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let w = summary.latest {
                MetricRow(label: WorkoutType.name(w.activityType), value: w.start.formatted(date: .abbreviated, time: .shortened))
                MetricRow(label: "1-min drop", value: w.recovery1.map { String(format: "%.0f bpm", $0) } ?? "–",
                          tint: tint(w.recovery1))
                if let d2 = w.drop120 { MetricRow(label: "2-min drop", value: String(format: "%.0f bpm", d2)) }
                if let p = w.peakHR { MetricRow(label: "Peak", value: String(format: "%.0f bpm", p)) }
            }
            if let t = summary.typicalDrop {
                MetricRow(label: "Typical 1-min drop", value: String(format: "%.0f bpm", t))
            }
            if summary.recent.count >= 2 {
                Chart(summary.recent) { p in
                    LineMark(x: .value("Workout", p.start), y: .value("Drop", p.drop)).foregroundStyle(.pink)
                    PointMark(x: .value("Workout", p.start), y: .value("Drop", p.drop)).foregroundStyle(.pink).symbolSize(12)
                }
                .chartXAxis(.hidden)
                .frame(height: 50)
            }
            Text("A bigger drop in the first minute after a workout usually comes with better aerobic fitness. Compare against your own typical value.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func tint(_ v: Double?) -> Color {
        guard let v, let t = summary.typicalDrop else { return .primary }
        return v >= t ? .green : (v < t - 5 ? .orange : .primary)
    }
}

// MARK: - Caffeine and water

struct IntakeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var customCaffeine = 80.0

    private let drinks: [(String, Double, String)] = [
        ("Espresso", 65, "cup.and.saucer"), ("Coffee", 95, "mug"), ("Tea", 45, "leaf"),
        ("Cola", 35, "takeoutbag.and.cup.and.straw"), ("Energy drink", 80, "bolt"),
    ]

    var body: some View {
        List {
            if let i = model.brief?.intake, model.brief?.isCurrent() == true {
                Section("Caffeine") {
                    MetricRow(label: "In your body now", value: String(format: "%.0f mg", i.caffeineNowMg))
                    MetricRow(label: "At bedtime \(i.bedtime.formatted(date: .omitted, time: .shortened))",
                              value: String(format: "%.0f mg", i.caffeineAtBedtimeMg),
                              tint: i.caffeineAtBedtimeMg >= i.limitMg ? .orange : .primary)
                    if let cut = i.cutoff {
                        MetricRow(label: cut > Date() ? "Cut-off" : "Cut-off (passed)",
                                  value: cut.formatted(date: .omitted, time: .shortened),
                                  tint: cut > Date() ? .green : .orange)
                    } else {
                        Text(String(format: "Already over %.0f mg at bedtime.", i.limitMg)).font(.footnote).foregroundStyle(.orange)
                    }
                    Chart(i.curve) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("mg", p.mg)).foregroundStyle(Color.brown.opacity(0.4))
                        RuleMark(y: .value("Limit", i.limitMg)).foregroundStyle(.orange.opacity(0.7))
                        RuleMark(x: .value("Bedtime", i.bedtime)).foregroundStyle(.indigo)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 60)
                    Text(i.bedtimeFromHistory ? "Bedtime is your usual sleep onset (last 7 nights)." : "Bedtime is the default until 3 nights of sleep are recorded.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Water") {
                    MetricRow(label: "Today", value: String(format: "%.0f / %.0f ml", i.waterTodayMl, i.waterTargetMl),
                              tint: i.waterTodayMl >= i.waterTargetMl ? .green : .primary)
                    HStack {
                        Button("+250") { model.addIntake(.water, amount: 250) }
                        Button("+500") { model.addIntake(.water, amount: 500) }
                    }
                }
            }
            Section("Log caffeine") {
                ForEach(drinks, id: \.0) { d in
                    Button {
                        model.addIntake(.caffeine, amount: d.1, label: d.0)
                    } label: {
                        HStack {
                            Label(d.0, systemImage: d.2)
                            Spacer()
                            Text("\(Int(d.1)) mg").foregroundStyle(.secondary)
                        }
                    }
                }
                Stepper("\(Int(customCaffeine)) mg", value: $customCaffeine, in: 10...400, step: 10)
                Button("Log \(Int(customCaffeine)) mg") { model.addIntake(.caffeine, amount: customCaffeine) }
            }
            if let entries = model.brief?.intake?.entriesToday, !entries.isEmpty {
                Section("Today") {
                    ForEach(entries.reversed()) { e in
                        HStack {
                            Text(e.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                            Text(e.label.isEmpty ? (e.kind == .caffeine ? "Caffeine" : "Water") : e.label)
                            Spacer()
                            Text(e.kind == .caffeine ? "\(Int(e.amount)) mg" : "\(Int(e.amount)) ml")
                        }
                        .font(.footnote)
                        .swipeActions {
                            Button(role: .destructive) { model.removeIntake(e.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Caffeine & water")
    }
}

// MARK: - Status

struct StatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if let active = model.activeStatus {
                Section {
                    Label("\(active.kind.title) since \(active.start.description)", systemImage: active.kind.symbol)
                    Button("End today") { model.endStatus(active.id) }
                }
            }
            Section("Mark today") {
                ForEach(StatusKind.allCases, id: \.self) { k in
                    Button {
                        model.startStatus(k)
                    } label: {
                        Label(k.title, systemImage: k.symbol)
                    }
                    .disabled(model.activeStatus?.kind == k)
                }
            }
            Section {
                Text("Marked days are left out of your personal baselines, so they don't drag later scores. Unwell and sore also pause the load model and turn Push off. Travel keeps the load model running.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            let past = model.statusPeriods.filter { $0.end != nil }.reversed()
            if !past.isEmpty {
                Section("History") {
                    ForEach(Array(past)) { p in
                        Text("\(p.kind.title): \(p.start.description) – \(p.end!.description)").font(.footnote)
                            .swipeActions {
                                Button(role: .destructive) { model.deleteStatus(p.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            }
        }
        .navigationTitle("Status")
    }
}

// MARK: - Timeline

/// The last few events of today, linking to the full timeline.
struct TodaySoFar: View {
    let brief: DailyBrief

    var body: some View {
        let items = (brief.timelines?.last?.items ?? []).filter { $0.kind != .journal }
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(text: "Today so far")
            if items.isEmpty { Text("Nothing recorded yet.").font(.caption2).foregroundStyle(.secondary) }
            ForEach(items.suffix(3)) { item in
                HStack(spacing: 4) {
                    Image(systemName: item.kind.symbol).foregroundStyle(item.kind.color).font(.caption2)
                    Text(item.title).font(.caption2).lineLimit(1)
                    Spacer()
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            NavigationLink { DayTimelineView() } label: { Text("Full timeline").font(.caption2) }
        }
    }
}

struct DayTimelineView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dayIndex: Int?

    var body: some View {
        List {
            let timelines = model.brief?.timelines ?? []
            if !timelines.isEmpty {
                Picker("Day", selection: Binding(get: { dayIndex ?? timelines.count - 1 }, set: { dayIndex = $0 })) {
                    ForEach(Array(timelines.enumerated()), id: \.offset) { k, t in
                        Text(k == timelines.count - 1 ? "Today" : (k == timelines.count - 2 ? "Yesterday" : t.day.description)).tag(k)
                    }
                }
            }
            if model.brief?.isCurrent() == true, !timelines.isEmpty,
               let t = Optional(timelines[min(dayIndex ?? timelines.count - 1, timelines.count - 1)]) {
                if t.items.isEmpty {
                    Text("Nothing recorded yet.").font(.footnote)
                }
                ForEach(t.items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.kind.symbol).foregroundStyle(item.kind.color).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(item.title).font(.footnote.weight(.semibold))
                                Spacer()
                                Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let s = item.source {
                                Text(s).font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                Text("No timeline yet.").font(.footnote)
            }
        }
        .navigationTitle("Timeline")
    }
}

// MARK: - Settings pages

struct PinnedMetricsView: View {
    @EnvironmentObject private var model: AppModel
    static let maxPinned = 6

    var body: some View {
        List {
            if !model.lifestyle.pinnedMetrics.isEmpty {
                Section("Order") {
                    ForEach(Array(model.lifestyle.pinnedMetrics.enumerated()), id: \.element) { k, m in
                        HStack {
                            Text(m.title).font(.footnote)
                            Spacer()
                            Button { movePinned(k, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(k == 0)
                            Button { movePinned(k, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
                                .disabled(k == model.lifestyle.pinnedMetrics.count - 1)
                        }
                    }
                }
            }
            Section {
                ForEach(DashboardMetric.allCases.filter { $0 != .recovery }, id: \.self) { m in
                    Toggle(m.title, isOn: Binding(
                        get: { model.lifestyle.pinnedMetrics.contains(m) },
                        set: { on in
                            var list = model.lifestyle.pinnedMetrics
                            if on { if !list.contains(m) && list.count < Self.maxPinned { list.append(m) } } else { list.removeAll { $0 == m } }
                            model.lifestyle.pinnedMetrics = list
                        }
                    ))
                    .disabled(!model.lifestyle.pinnedMetrics.contains(m) && model.lifestyle.pinnedMetrics.count >= Self.maxPinned)
                }
            } footer: {
                Text("Up to \(Self.maxPinned) tiles under the recovery ring on Today. Reorder them above.")
            }
        }
        .navigationTitle("Today tiles")
    }

    private func movePinned(_ k: Int, _ offset: Int) {
        var list = model.lifestyle.pinnedMetrics
        let j = k + offset
        guard list.indices.contains(k), list.indices.contains(j) else { return }
        list.swapAt(k, j)
        model.lifestyle.pinnedMetrics = list
    }
}

struct LifestyleSettingsSections: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Today screen") {
            NavigationLink("Pinned tiles (\(model.lifestyle.pinnedMetrics.count))") { PinnedMetricsView() }
        }
        Section("Caffeine") {
            Stepper(String(format: "Half-life %.1f h", model.lifestyle.caffeineHalfLifeHours),
                    value: $model.lifestyle.caffeineHalfLifeHours, in: 2...10, step: 0.5)
            Stepper(String(format: "Bedtime limit %.0f mg", model.lifestyle.bedtimeCaffeineLimitMg),
                    value: $model.lifestyle.bedtimeCaffeineLimitMg, in: 10...150, step: 10)
            Stepper(String(format: "Usual dose %.0f mg", model.lifestyle.typicalDoseMg),
                    value: $model.lifestyle.typicalDoseMg, in: 20...300, step: 5)
        }
        Section("Water") {
            Stepper(String(format: "%.0f ml per kg", model.lifestyle.waterMlPerKg),
                    value: $model.lifestyle.waterMlPerKg, in: 25...50, step: 1)
            Toggle("Set body mass", isOn: Binding(
                get: { model.lifestyle.bodyMassKg != nil },
                set: { model.lifestyle.bodyMassKg = $0 ? (model.lifestyle.bodyMassKg ?? (model.healthBodyMassKg ?? 70).rounded()) : nil }
            ))
            if let kg = model.lifestyle.bodyMassKg {
                Stepper("\(Int(kg)) kg", value: Binding(get: { kg }, set: { model.lifestyle.bodyMassKg = $0 }), in: 35...200, step: 1)
            } else {
                Text(model.healthBodyMassKg.map { String(format: "%.0f kg from Health", $0) } ?? "70 kg default").font(.footnote)
            }
        }
        Section("Check-ins") {
            Toggle("Morning summary", isOn: $model.lifestyle.checkIns.morningSummary)
            Toggle("Evening journal", isOn: $model.lifestyle.checkIns.eveningJournal)
            if model.lifestyle.checkIns.eveningJournal {
                Stepper(clock(model.lifestyle.checkIns.eveningJournalMinutes),
                        value: $model.lifestyle.checkIns.eveningJournalMinutes, in: 17 * 60...23 * 60 + 30, step: 30)
            }
            Toggle("Caffeine cut-off", isOn: $model.lifestyle.checkIns.caffeineCutoff)
            Toggle("Weekly review (Sun)", isOn: $model.lifestyle.checkIns.weeklyReview)
        }
    }

    private func clock(_ minutes: Int) -> String {
        String(format: "At %02d:%02d", minutes / 60, minutes % 60)
    }
}
