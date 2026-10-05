import Charts
import SwiftUI
import MarginCore
import UserNotifications

@main
struct MarginPhoneApp: App {
    @StateObject private var model = PhoneModel.shared
    @StateObject private var coach = CoachModel.shared
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        CoachModel.shared.scheduleCheckIns()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                PhoneTodayView().tabItem { Label("Today", systemImage: "heart.text.square") }.tag(0)
                PhoneTrendsView().tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }.tag(1)
                CoachView().tabItem { Label("Coach", systemImage: "bubble.left.and.text.bubble.right") }.tag(2)
                PhoneBodyView().tabItem { Label("Body", systemImage: "figure.stand") }.tag(3)
                PhoneSettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
            }
            .environmentObject(model)
            .environmentObject(coach)
            .onChange(of: coach.pendingPrompt) { _, p in if p != nil { tab = 2 } }
            .modifier(MinimizingTabBar())
            .onChange(of: phase) { _, p in
                if p == .active {
                    model.requestRefresh()
                    Task { await model.refreshMealsToday() }
                }
            }
        }
    }
}

/// iOS 26: the glass tab bar shrinks while scrolling down.
struct MinimizingTabBar: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Shown wherever the watch hasn't sent anything for today yet.
struct NoDataView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        ContentUnavailableView {
            Label("Waiting for your watch", systemImage: "applewatch")
        } description: {
            Text(model.payload == nil
                 ? "Open Margin on your Apple Watch once. It sends your scores here after each sync."
                 : "The latest data is from \(model.payload!.brief.day.description). Open Margin on your watch to update.")
        }
    }
}

// MARK: - Today

struct PhoneTodayView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            ScrollView {
                if let b = model.brief, b.isCurrent() {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            RecoveryDial(recovery: b.recovery).frame(width: 132, height: 132)
                            VStack(alignment: .leading, spacing: 6) {
                                Label(b.plan.directive.title, systemImage: b.plan.directive.symbol)
                                    .font(.title3.bold()).foregroundStyle(b.plan.directive.color)
                                if let lo = b.strain?.targetLow, let hi = b.strain?.targetHigh {
                                    Text("Strain target \(lo)–\(hi)").font(.subheadline)
                                }
                                ForEach(b.plan.reasons.prefix(2), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                                if b.recovery.status != .scored {
                                    Text(b.recovery.statusDetail).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .glassCard(cornerRadius: 28, tint: b.recovery.band.color)
                        GlassGroup(spacing: 12) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                ForEach(model.pinned, id: \.self) { m in
                                    PhoneTile(tile: tile(m, b))
                                }
                            }
                        }
                        if let x = b.explanation, b.recovery.score != nil {
                            Card(title: "Why today") { ExplanationView(explanation: x) }
                        }
                        if let e = b.energy {
                            Card(title: "Energy bank") {
                                Chart(e.points) { p in
                                    AreaMark(x: .value("Time", p.date), y: .value("Energy", p.level)).foregroundStyle(.yellow.opacity(0.3))
                                    LineMark(x: .value("Time", p.date), y: .value("Energy", p.level)).foregroundStyle(.yellow)
                                }
                                .chartYScale(domain: 0...100)
                                .frame(height: 120)
                                Text("\(e.current) now, from \(e.start) at wake. Load −\(Int(e.drainedByStrain)), stress −\(Int(e.drainedByStress)), calm rest +\(Int(e.chargedByRest)).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let s = b.stress, !s.hours.isEmpty {
                            Card(title: "Stress by hour") {
                                Chart(s.hours.filter { $0.level != nil }) { h in
                                    BarMark(x: .value("Hour", h.start, unit: .hour), y: .value("Stress", h.level ?? 0))
                                        .foregroundStyle(StressBand(level: h.level ?? 0).color)
                                }
                                .chartYScale(domain: 0...100)
                                .frame(height: 100)
                            }
                        }
                        if let t = b.timelines?.last, !t.items.isEmpty {
                            Card(title: "Today") {
                                ForEach(t.items) { item in
                                    HStack(alignment: .top) {
                                        Image(systemName: item.kind.symbol).foregroundStyle(item.kind.color).frame(width: 22)
                                        VStack(alignment: .leading) {
                                            Text(item.title).font(.subheadline.weight(.semibold))
                                            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        SyncFooter()
                    }
                    .padding()
                } else {
                    NoDataView().padding(.top, 80)
                }
            }
            .refreshable { model.requestRefresh() }
            .background { MarginBackdrop(tint: model.brief?.recovery.band.color ?? .gray) }
            .navigationTitle("Today")
        }
    }

    private func tile(_ m: DashboardMetric, _ b: DailyBrief) -> DashboardTile {
        m == .topLift || m == .muscles
            ? DashboardTile.makeStrength(m, brief: b, now: Date(), calendar: .current, unit: model.unit)
            : DashboardTile.make(m, brief: b, now: Date(), calendar: .current)
    }
}

struct RecoveryDial: View {
    let recovery: Recovery

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 14)
            Circle().trim(from: 0, to: CGFloat(recovery.score ?? 0) / 100)
                .stroke(recovery.band.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(recovery.score.map { "\($0)" } ?? "–").font(.system(size: 44, weight: .bold, design: .rounded))
                Text("RECOVERY").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct PhoneTile: View {
    let tile: DashboardTile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.metric.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(tile.value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(tile.tone.color)
                .minimumScaleFactor(0.5).lineLimit(1)
            if let f = tile.fraction { ProgressView(value: f).tint(tile.tone.color) }
            Text(tile.caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 22, tint: tile.tone == .neutral ? nil : tile.tone.color, interactive: true)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 24)
    }
}

struct SyncFooter: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        VStack(spacing: 2) {
            if let at = model.lastReceivedAt {
                Text("From your watch \(at.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
            }
            if let e = model.syncError { Text(e).font(.caption2).foregroundStyle(.orange) }
        }
    }
}

// MARK: - Trends

struct PhoneTrendsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var a: CompareMetric = .caffeine
    @State private var b: CompareMetric = .hrv
    @State private var nextDay = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if let brief = model.brief {
                    VStack(spacing: 16) {
                        Card(title: "Recovery, 14 days") {
                            Chart(brief.history) { p in
                                if let s = p.recoveryScore {
                                    BarMark(x: .value("Day", p.day.date(hour: 12, calendar: .current), unit: .day), y: .value("Recovery", s))
                                        .foregroundStyle(s >= 67 ? Color.green : (s <= 33 ? .red : .yellow))
                                }
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 140)
                        }
                        Card(title: "HRV and load") {
                            Chart {
                                ForEach(brief.history) { p in
                                    if let l = p.load {
                                        BarMark(x: .value("Day", p.day.date(hour: 12, calendar: .current), unit: .day), y: .value("Load", l))
                                            .foregroundStyle(.orange.opacity(0.6))
                                    }
                                    if let c = p.ctl {
                                        LineMark(x: .value("Day", p.day.date(hour: 12, calendar: .current), unit: .day), y: .value("CTL", c))
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                            .frame(height: 140)
                            Chart(brief.history) { p in
                                if let h = p.hrvMs {
                                    LineMark(x: .value("Day", p.day.date(hour: 12, calendar: .current), unit: .day), y: .value("HRV", h))
                                        .foregroundStyle(.green)
                                    PointMark(x: .value("Day", p.day.date(hour: 12, calendar: .current), unit: .day), y: .value("HRV", h))
                                        .foregroundStyle(.green)
                                }
                            }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .frame(height: 100)
                        }
                        if let ins = brief.metricInsights, !ins.isEmpty { PhoneInsightsCard(insights: ins) }
                        Card(title: "Compare") {
                            HStack {
                                Picker("First", selection: $a) { ForEach(CompareMetric.allCases, id: \.self) { Text($0.title).tag($0) } }
                                Picker("Second", selection: $b) { ForEach(CompareMetric.allCases, id: \.self) { Text($0.title).tag($0) } }
                            }
                            Toggle("Second metric on the next day", isOn: $nextDay).font(.subheadline)
                            CompareChart(series: brief.series ?? [], a: a, b: b, lag: nextDay ? 1 : 0)
                        }
                    }
                    .padding()
                } else {
                    NoDataView().padding(.top, 80)
                }
            }
            .background { MarginBackdrop(tint: .indigo) }
            .navigationTitle("Trends")
        }
    }
}

struct CompareChart: View {
    let series: [MetricSeries]
    let a: CompareMetric
    let b: CompareMetric
    let lag: Int

    var body: some View {
        if let sa = series.first(where: { $0.metric == a }), let sb = series.first(where: { $0.metric == b }) {
            let pairs = Correlation.pairs(sa, sb, lagDays: lag, calendar: .current)
            if pairs.count >= 3 {
                Chart(Array(pairs.enumerated()), id: \.offset) { _, p in
                    PointMark(x: .value(a.title, p.x), y: .value(b.title, p.y)).foregroundStyle(.cyan)
                }
                .chartXAxisLabel(a.title)
                .chartYAxisLabel(b.title)
                .frame(height: 180)
                if let r = Correlation.spearman(pairs.map(\.x), pairs.map(\.y)) {
                    Text(String(format: "Spearman ρ %+.2f over %d days%@", r.rho, r.n, r.pValue.map { String(format: " · p %.3f", $0) } ?? ""))
                        .font(.caption)
                }
                Text("An association in your own data, not a cause.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Fewer than 3 days with both values.").font(.caption)
            }
        }
    }
}

// MARK: - Body (biomarkers, strength, cycle, running, labs, food)

struct PhoneBodyView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                PhoneHealthSection()
                if let bio = model.brief?.biomarkers {
                    if let age = bio.biologicalAge {
                        Section("Biological age") {
                            HStack {
                                Text(String(format: "%.0f", age.estimate)).font(.largeTitle.bold())
                                Text(String(format: "%+.1f years vs your age", age.estimate - Double(age.chronological))).foregroundStyle(.secondary)
                            }
                            ForEach(age.components) { c in
                                LabeledContent(c.name, value: String(format: "%+.1f y", c.years))
                            }
                        }
                    }
                    Section("Trends") {
                        trend("VO2 max", bio.vo2Max, "mL/kg/min", 1)
                        trend("Resting HR", bio.restingHR, "bpm", 0)
                        trend("Body mass", bio.bodyMass, "kg", 1)
                        trend("Body fat", bio.bodyFat, "%", 1)
                        trend("Lean mass", bio.leanMass, "kg", 1)
                        if let bp = bio.bloodPressure {
                            LabeledContent("Blood pressure", value: String(format: "%.0f/%.0f · %@", bp.latestSystolic, bp.latestDiastolic, bp.category.title))
                        }
                        if let g = bio.glucose { LabeledContent("Glucose", value: String(format: "%.0f mg/dL", g.latest)) }
                    }
                    if let c = bio.cycle {
                        Section("Cycle") {
                            LabeledContent("Day \(c.cycleDay)", value: c.phase.title)
                            LabeledContent("Next period", value: c.predictedNextStart.description)
                        }
                    }
                    if let r = bio.running {
                        Section("Latest run") {
                            if let c = r.latest.cadence { LabeledContent("Cadence", value: String(format: "%.0f spm", c)) }
                            if let s = r.latest.strideLengthM { LabeledContent("Stride", value: String(format: "%.2f m", s)) }
                            if let g = r.latest.groundContactMs { LabeledContent("Ground contact", value: String(format: "%.0f ms", g)) }
                            if let v = r.latest.verticalOscillationCm { LabeledContent("Vertical oscillation", value: String(format: "%.1f cm", v)) }
                        }
                    }
                }
                if let st = model.brief?.strength {
                    Section("Muscles") {
                        ForEach(st.muscles.sorted { $0.freshness < $1.freshness }.prefix(6)) { m in
                            LabeledContent(m.muscle.title, value: "\(m.freshness) · \(String(format: "%.0f", m.weeklySets)) sets/wk")
                        }
                    }
                }
                Section {
                    NavigationLink { PhoneActivitiesView() } label: { Label("Activities", systemImage: "figure.mixed.cardio") }
                    NavigationLink {
                        ScrollView { VStack(spacing: 10) { SleepHistoryList(nights: model.brief?.sleepHistory ?? []) }.padding() }
                            .navigationTitle("Sleep history")
                    } label: { Label("Sleep history", systemImage: "bed.double") }
                    NavigationLink { PhoneRoutinesView() } label: { Label("Routines", systemImage: "list.bullet.clipboard") }
                    NavigationLink { LabsView() } label: { Label("Lab results", systemImage: "testtube.2") }
                    NavigationLink { FoodLogView() } label: { Label("Log food", systemImage: "fork.knife") }
                }
            }
            .scrollContentBackground(.hidden)
            .background { MarginBackdrop(tint: .teal) }
            .navigationTitle("Body")
        }
    }

    @ViewBuilder
    private func trend(_ title: String, _ t: Trend?, _ unit: String, _ digits: Int) -> some View {
        if let t {
            VStack(alignment: .leading) {
                LabeledContent(title, value: String(format: "%.\(digits)f %@", t.latest, unit))
                if let s = t.slopePerWeek, let p = t.projected30 {
                    Text(String(format: "%+.2f/week · 30 days: %.\(digits)f", s, p)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Labs

struct LabsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var adding = false

    var body: some View {
        List {
            if model.labs.isEmpty {
                Text("Add results from your lab reports to track them over time and give the coach context. Enter the reference range printed on your report.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.labSeries) { s in
                NavigationLink { LabSeriesView(series: s) } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(s.latest.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%g %@", s.latest.value, s.unit))
                            .foregroundStyle(s.latest.withinReference == false ? .orange : .primary)
                    }
                }
            }
        }
        .navigationTitle("Lab results")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $adding) { AddLabView() }
    }
}

struct LabSeriesView: View {
    @EnvironmentObject private var model: PhoneModel
    let series: LabSeries

    var body: some View {
        List {
            Chart(series.results) { r in
                LineMark(x: .value("Date", r.date), y: .value(series.name, r.value))
                PointMark(x: .value("Date", r.date), y: .value(series.name, r.value))
                if let lo = series.latest.referenceLow { RuleMark(y: .value("Low", lo)).foregroundStyle(.green.opacity(0.5)) }
                if let hi = series.latest.referenceHigh { RuleMark(y: .value("High", hi)).foregroundStyle(.green.opacity(0.5)) }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 180)
            if let c = series.change {
                LabeledContent("Change since previous", value: String(format: "%+g %@", c, series.unit))
            }
            ForEach(series.results.reversed()) { r in
                HStack {
                    Text(r.date.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    Text(String(format: "%g", r.value))
                    if let ok = r.withinReference {
                        Image(systemName: ok ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
                    }
                }
                .swipeActions { Button(role: .destructive) { model.deleteLab(r.id) } label: { Label("Delete", systemImage: "trash") } }
            }
            Text("Within or outside the reference range on your report. Discuss results with your clinician.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle(series.name)
    }
}

struct AddLabView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var marker: LabMarker = .ldl
    @State private var name = ""
    @State private var value = ""
    @State private var unit = LabMarker.ldl.defaultUnit
    @State private var date = Date()
    @State private var low = ""
    @State private var high = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Marker", selection: $marker) { ForEach(LabMarker.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .onChange(of: marker) { _, m in unit = m.defaultUnit }
                if marker == .custom { TextField("Name", text: $name) }
                TextField("Value", text: $value).keyboardType(.decimalPad)
                TextField("Unit", text: $unit)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Section("Reference range (from your report)") {
                    TextField("Low", text: $low).keyboardType(.decimalPad)
                    TextField("High", text: $high).keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Add result")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = Double(value.replacingOccurrences(of: ",", with: ".")) else { return }
                        model.addLab(LabResult(marker: marker, name: marker == .custom ? name : nil, value: v, unit: unit, date: date,
                                               referenceLow: Double(low.replacingOccurrences(of: ",", with: ".")),
                                               referenceHigh: Double(high.replacingOccurrences(of: ",", with: "."))))
                        dismiss()
                    }
                    .disabled(Double(value.replacingOccurrences(of: ",", with: ".")) == nil || (marker == .custom && name.isEmpty))
                }
            }
        }
    }
}

// MARK: - Food

struct FoodLogView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var name = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            if let t = model.mealsToday {
                Section("Today in Health") {
                    LabeledContent("Energy", value: t.energyKcal.map { String(format: "%.0f kcal", $0) } ?? "–")
                    LabeledContent("Protein / carbs / fat", value: [t.proteinG, t.carbsG, t.fatG].map { $0.map { String(format: "%.0f", $0) } ?? "–" }.joined(separator: " / ") + " g")
                }
            }
            Section("Log a meal") {
                TextField("What (optional)", text: $name)
                TextField("kcal", text: $kcal).keyboardType(.decimalPad)
                TextField("Protein g", text: $protein).keyboardType(.decimalPad)
                TextField("Carbs g", text: $carbs).keyboardType(.decimalPad)
                TextField("Fat g", text: $fat).keyboardType(.decimalPad)
                Button("Save to Health") {
                    Task {
                        do {
                            try await model.logMeal(kcal: Double(kcal), protein: Double(protein), carbs: Double(carbs), fat: Double(fat), name: name)
                            name = ""; kcal = ""; protein = ""; carbs = ""; fat = ""
                            saved = true
                            error = nil
                        } catch let e {
                            error = e.localizedDescription
                        }
                    }
                }
                .disabled([kcal, protein, carbs, fat].allSatisfy { Double($0) == nil })
                if saved { Text("Saved.").foregroundStyle(.green).font(.caption) }
                if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            }
            Text("Meals are written to Health as energy and macronutrients, so any app that reads Health (and Margin's Body page) sees them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Log food")
        .task { await model.refreshMealsToday() }
    }
}

// MARK: - Settings

struct PhoneSettingsView: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var coach: CoachModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Watch") {
                    LabeledContent("Paired", value: model.watchPaired ? "Yes" : "No")
                    LabeledContent("Reachable now", value: model.watchReachable ? "Yes" : "No")
                    if let at = model.lastReceivedAt { LabeledContent("Last data", value: at.formatted(date: .abbreviated, time: .shortened)) }
                    Button("Ask the watch to sync") { model.requestRefresh() }.disabled(!model.watchReachable)
                }
                Section("Today tiles") {
                    ForEach(DashboardMetric.allCases.filter { $0 != .recovery }, id: \.self) { m in
                        Toggle(m.title, isOn: Binding(
                            get: { model.pinned.contains(m) },
                            set: { on in
                                if on { if !model.pinned.contains(m) { model.pinned.append(m) } } else { model.pinned.removeAll { $0 == m } }
                            }))
                    }
                }
                CoachSettingsSection()
            }
            .scrollContentBackground(.hidden)
            .background { MarginBackdrop(tint: .gray) }
            .navigationTitle("Settings")
        }
    }
}
