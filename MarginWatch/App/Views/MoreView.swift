import SwiftUI
import MarginCore

struct MoreView: View {
    var body: some View {
        List {
            NavigationLink { JournalView() } label: { Label("Journal", systemImage: "book.closed") }
            NavigationLink { InsightsView() } label: { Label("Insights", systemImage: "chart.bar.xaxis") }
            NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
            NavigationLink { AboutView() } label: { Label("How it works", systemImage: "info.circle") }
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
            Section("Risk limit") {
                Stepper(String(format: "ACWR ceiling %.2f", model.settings.acwrCeiling),
                        value: $model.settings.acwrCeiling, in: 1.1...1.6, step: 0.05)
            }
            Section("Data") {
                Button("Rebuild from Health") { confirmRebuild = true }
                    .disabled(model.isRefreshing)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Re-read up to \(AppModel.historyDays) days from Health?", isPresented: $confirmRebuild) {
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
                    Text("Overnight HRV (ln SDNN), sleeping HR, sleep vs need, respiration and wrist temperature are each scored against your own 60-day median/MAD baseline. The weighted composite is then compared with your own recent days, so 50 = a typical day for you.")
                    Text("Directive").font(.headline)
                    Text("Recover needs a bottom-15% day, or a bottom-third day confirmed by a low 7-day HRV trend or sleep debt. Push is demoted on weak or conflicting evidence. Rest requires sleeping HR AND temperature or respiration ≥ +2 SD.")
                    Text("Load").font(.headline)
                    Text("Banister TRIMP from heart-rate reserve. ATL = 7-day and CTL = 42-day exponential averages. The ceiling is the most load today that keeps ATL/CTL under your limit.")
                    Text("Limits").font(.headline)
                    Text("Wellness tool, not a medical device. Thresholds are heuristics, validated on simulated data only.")
                }
                .font(.caption2)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("How it works")
    }
}
