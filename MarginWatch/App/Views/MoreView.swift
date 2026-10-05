import SwiftUI
import MarginCore

struct MoreView: View {
    var body: some View {
        List {
            NavigationLink { LogActivityView() } label: { Label("Log activity", systemImage: "plus.circle") }
            NavigationLink { RoutinesView() } label: { Label("Routines", systemImage: "list.bullet.clipboard") }
            NavigationLink { StrengthHomeView() } label: { Label("Strength", systemImage: "figure.strengthtraining.traditional") }
            NavigationLink { DayTimelineView() } label: { Label("Timeline", systemImage: "list.bullet.rectangle") }
            NavigationLink { IntakeView() } label: { Label("Caffeine & water", systemImage: "cup.and.saucer") }
            NavigationLink { StatusView() } label: { Label("Status", systemImage: "flag") }
            NavigationLink { RunningView() } label: { Label("Running form", systemImage: "figure.run") }
            NavigationLink { CycleView() } label: { Label("Cycle", systemImage: "circle.dashed") }
            NavigationLink { CompareView() } label: { Label("Compare", systemImage: "chart.xyaxis.line") }
            NavigationLink { JournalView() } label: { Label("Journal", systemImage: "book.closed") }
            NavigationLink { InsightsView() } label: { Label("Insights", systemImage: "chart.bar.xaxis") }
            NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
            NavigationLink { AboutView() } label: { Label("How it works", systemImage: "info.circle") }
            #if DEBUG
            NavigationLink { DiagnosticsView() } label: { Label("Developer diagnostics", systemImage: "wrench.and.screwdriver") }
            #endif
        }
        .navigationTitle("More")
    }
}

// MARK: - Journal

/// Behaviours logged for a day are tested against the *next* night's HRV.
struct JournalView: View {
    @EnvironmentObject private var model: AppModel
    @State private var offset = -1

    private var day: Day { model.today.adding(offset, calendar: .current) }

    var body: some View {
        List {
            Picker("Day", selection: $offset) {
                Text("Yesterday").tag(-1)
                Text("Today").tag(0)
            }
            let tags = model.tags(on: day)
            ForEach(AppModel.defaultTags, id: \.self) { tag in
                Toggle(tag, isOn: Binding(
                    get: { tags?.contains(tag) ?? false },
                    set: { model.setTag(tag, on: day, enabled: $0) }
                ))
            }
            if tags == nil {
                Button("Nothing notable") { model.confirmJournal(day) }
            } else {
                Label("Logged", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Clear entry", role: .destructive) { model.clearJournal(day) }
            }
        }
        .navigationTitle(day.description)
    }
}

// MARK: - Insights

struct InsightsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if let impacts = model.brief?.tagImpacts, !impacts.isEmpty {
                ForEach(impacts) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(i.tag).font(.footnote.weight(.semibold))
                            Spacer()
                            Text(String(format: "%+.0f%% HRV", i.effectPercent))
                                .font(.footnote)
                                .foregroundStyle(i.significant ? (i.effectPercent < 0 ? Color.red : Color.green) : Color.secondary)
                        }
                        Text("n \(i.nWith) vs \(i.nWithout) · p \(String(format: "%.3f", i.pValue))\(i.significant ? " · significant" : " · not significant")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Next-night HRV vs baseline; Welch t-test, Holm-corrected at α = 0.05. Associations, not causation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Log the journal daily. A tag is tested once it has ≥5 days with and ≥5 journaled days without it.")
                    .font(.footnote)
            }
            if let pairs = model.brief?.metricInsights, !pairs.isEmpty {
                Section("Metric pairs, 60 days") {
                    ForEach(pairs) { p in MetricPairRow(insight: p) }
                    Text("A fixed list of pairs, tested with Spearman's ρ and Holm-corrected at α = 0.05. Needs \(MetricPairs.minimumN) days with both values. Associations, not causes.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Insights")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmRebuild = false

    var body: some View {
        List {
            Section("Heart rate") {
                Toggle("Measured HRmax", isOn: Binding(
                    get: { model.settings.hrMaxOverride != nil },
                    set: { model.settings.hrMaxOverride = $0 ? (model.settings.hrMaxOverride ?? model.settings.resolvedHRMax.rounded()) : nil }
                ))
                if let hrMax = model.settings.hrMaxOverride {
                    Stepper("HRmax \(Int(hrMax))", value: Binding(
                        get: { hrMax },
                        set: { model.settings.hrMaxOverride = $0 }
                    ), in: 140...230, step: 1)
                } else {
                    Text("HRmax \(Int(model.settings.resolvedHRMax.rounded())) (\(model.settings.age == nil ? "default" : "208 − 0.7 × age"))")
                        .font(.footnote)
                }
                Picker("Sex (load formula)", selection: $model.settings.sex) {
                    Text("Male").tag(Sex.male)
                    Text("Female").tag(Sex.female)
                    Text("Unspecified").tag(Sex.unspecified)
                }
            }
            Section("Sleep") {
                Stepper(String(format: "Base need %.2fh", model.settings.baseSleepNeedHours),
                        value: $model.settings.baseSleepNeedHours, in: 6...10, step: 0.25)
            }
            Section("Load-change limit") {
                Stepper(String(format: "ACWR ceiling %.2f", model.settings.acwrCeiling),
                        value: $model.settings.acwrCeiling, in: 1.1...1.6, step: 0.05)
            }
            StrengthSettingsSection()
            Section("Training and sleep") {
                NavigationLink("Heart-rate zones") { ZonesSettingsView() }
                NavigationLink("Smart alarm") { SmartAlarmSettingsView(alarm: model.smartAlarm) }
            }
            LifestyleSettingsSections()
            Section("Data") {
                Button("Rebuild from Health") { confirmRebuild = true }
                    .disabled(model.isRefreshing)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Re-read up to \(model.syncParams.historyDays) days from Health?", isPresented: $confirmRebuild) {
            Button("Rebuild") { Task { await model.rebuildHistory() } }
        }
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    Text("Recovery").font(.headline)
                    Text("Overnight HRV (ln SDNN), sleeping HR, sleep vs need, respiration and wrist temperature are each compared with your own 60-day median/MAD baseline. The weighted composite is then compared with your own recent days, so 50 = a typical day for you.")
                    Text("When there is no score").font(.headline)
                    Text("No number is shown while calibrating (fewer than 14 nights with HRV), while the night is still in progress, or when last night's HRV and sleeping HR are both missing. With one of them missing the score is marked Partial and Push is disabled.")
                    Text("Recommendation").font(.headline)
                    Text("Recover needs a bottom-15% day, or a bottom-third day confirmed by a low 7-day HRV trend or sleep debt. Push needs full inputs, a calibrated scale and no conflicting signal. Rest is suggested when sleeping HR and temperature or respiration are both at least 2 SD above your usual range.")
                    Text("Load").font(.headline)
                    Text("Banister TRIMP from heart-rate reserve. ATL = 7-day and CTL = 42-day exponential averages. The ceiling is the most load today that keeps ATL/CTL under your chosen limit.")
                }
                Group {
                    Text("What this is not").font(.headline)
                    Text("A training aid based on available sensor readings. It does not detect or assess any health condition. Push does not mean a workout is right for you, and Recover or Rest does not mean you are unwell. Thresholds are heuristics validated on simulated data only. Not a medical device.")
                }
                .font(.caption2)
            }
            .font(.caption2)
            .padding(.horizontal, 4)
        }
        .navigationTitle("How it works")
    }
}
