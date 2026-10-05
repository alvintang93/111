import SwiftUI
import MarginCore

/// Log activity: record one live (heart rate sampled by the watch, saved to
/// Health), or add one that already happened.
struct LogActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if model.activeActivity != nil {
                NavigationLink { ActiveActivityView() } label: {
                    Label("Resume \(WorkoutType.name(model.activeActivity!.activityType))", systemImage: "record.circle").foregroundStyle(.green)
                }
            }
            Section("Start now") {
                ForEach(ActivityCatalog.common.filter { !ActivityCatalog.strengthTypes.contains($0) }.prefix(10), id: \.self) { t in
                    NavigationLink {
                        ActiveActivityView().task { await model.startActivity(type: t, indoor: ![37, 52, 13, 24].contains(t)) }
                    } label: {
                        Label(WorkoutType.name(t), systemImage: ActivityIcon.symbol(t))
                    }
                    .disabled(model.activeActivity != nil || model.activeSessionID != nil)
                }
                NavigationLink { StrengthHomeView() } label: { Label("Strength", systemImage: "dumbbell") }
            }
            Section("Already done") {
                NavigationLink { PastActivityForm() } label: { Label("Add past activity", systemImage: "plus.circle") }
            }
            Section {
                NavigationLink { ActivityHistoryView() } label: { Label("Activity history", systemImage: "list.bullet") }
            }
        }
        .navigationTitle("Log activity")
    }
}

enum ActivityIcon {
    static func symbol(_ type: UInt) -> String {
        switch type {
        case 37: return "figure.run"
        case 52: return "figure.walk"
        case 13: return "figure.outdoor.cycle"
        case 46: return "figure.pool.swim"
        case 63: return "figure.highintensity.intervaltraining"
        case 50, 20: return "dumbbell"
        case 24: return "figure.hiking"
        case 57: return "figure.yoga"
        case 35: return "figure.rower"
        case 16: return "figure.elliptical"
        case 66: return "figure.pilates"
        case 77: return "figure.dance"
        default: return "figure.mixed.cardio"
        }
    }
}

struct ActiveActivityView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var session = AppModel.shared.strengthWorkout
    @Environment(\.dismiss) private var dismiss
    @State private var rpe = 5
    @State private var useRPE = false
    @State private var notes = ""
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let a = model.activeActivity {
                    Label(WorkoutType.name(a.activityType), systemImage: ActivityIcon.symbol(a.activityType)).font(.headline)
                    if let start = session.startDate {
                        Text(start, style: .timer).font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    }
                    HStack {
                        if let hr = session.heartRate { Label("\(Int(hr))", systemImage: "heart.fill").foregroundStyle(.red) }
                        if let kcal = session.activeEnergyKcal { Label("\(Int(kcal)) kcal", systemImage: "flame") }
                    }
                    .font(.footnote.monospacedDigit())
                    Toggle("RPE", isOn: $useRPE)
                    if useRPE { Stepper("RPE \(rpe)", value: $rpe, in: 1...10) }
                    TextField("Notes", text: $notes)
                    Button("End") { confirmEnd = true }.glassButton(prominent: true).tint(.red)
                } else {
                    Text("Starting…").font(.footnote)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Activity")
        .confirmationDialog("End this activity?", isPresented: $confirmEnd) {
            Button("Save to Health") { Task { await model.endActivity(save: true, rpe: useRPE ? rpe : nil, notes: notes); dismiss() } }
            Button("Discard", role: .destructive) { Task { await model.endActivity(save: false, rpe: nil, notes: ""); dismiss() } }
        }
    }
}

struct PastActivityForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var type: UInt = 37
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var minutes = 30
    @State private var useRPE = true
    @State private var rpe = 5
    @State private var notes = ""
    @State private var saveToHealth = true
    @State private var result: String?

    var body: some View {
        List {
            Picker("Activity", selection: $type) {
                ForEach(ActivityCatalog.common, id: \.self) { t in Text(WorkoutType.name(t)).tag(t) }
            }
            DatePicker("Start", selection: $start, in: ...Date())
            Stepper("\(minutes) min", value: $minutes, in: 5...600, step: 5)
            Toggle("RPE", isOn: $useRPE)
            if useRPE { Stepper("RPE \(rpe)", value: $rpe, in: 1...10) }
            TextField("Notes", text: $notes)
            Toggle("Save to Health", isOn: $saveToHealth)
            Button("Log activity") {
                Task {
                    let outcome = await model.logPastActivity(type: type, start: start, minutes: minutes, rpe: useRPE ? rpe : nil,
                                                              notes: notes, saveToHealth: saveToHealth)
                    switch outcome {
                    case .saved: result = "Logged and saved to Health."
                    case .linkedToExisting(let s): result = "Health already has this workout (\(s)). Linked to it instead of saving a duplicate."
                    case .loggedOnly: result = "Logged in Margin."
                    case .failed(let why): result = "Logged in Margin, but saving to Health failed: \(why)"
                    }
                }
            }
            .glassButton(prominent: true)
            if let result {
                Text(result).font(.caption2).foregroundStyle(.secondary)
                Button("Done") { dismiss() }
            }
            Text("A logged activity has no heart rate of its own, so it adds nothing to training load (TRIMP). RPE × minutes is shown as session load for context.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .navigationTitle("Past activity")
    }
}

struct ActivityHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: LoggedActivity?

    var body: some View {
        List {
            let entries = (model.brief?.activities ?? []).reversed()
            if entries.isEmpty { Text("No activities in the last 14 days.").font(.footnote) }
            ForEach(Array(entries)) { e in
                NavigationLink {
                    ScrollView { WorkoutAnalysisView(entry: e).padding(.horizontal, 4) }.navigationTitle("Workout")
                } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Label(e.title, systemImage: ActivityIcon.symbol(e.activityType)).font(.footnote.weight(.semibold))
                    Text("\(e.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(e.end.timeIntervalSince(e.start) / 60)) min")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(provenance(e)).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let l = e.logged?.sessionLoad { Text(String(format: "Session load %.0f (RPE × min)", l)).font(.system(size: 10)) }
                }
                }
                .swipeActions {
                    if let l = e.logged {
                        Button(role: .destructive) { deleting = l } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("Activities")
        .confirmationDialog("Delete this activity?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if deleting?.healthWorkoutID != nil {
                Button("Delete here and in Health", role: .destructive) {
                    if let d = deleting { Task { await model.deleteActivity(d.id, alsoFromHealth: true) } }
                    deleting = nil
                }
            }
            Button("Delete from Margin only", role: .destructive) {
                if let d = deleting { Task { await model.deleteActivity(d.id, alsoFromHealth: false) } }
                deleting = nil
            }
        }
    }

    private func provenance(_ e: ActivityEntry) -> String {
        switch (e.kind, e.match) {
        case (.healthWorkout, _): return "From Health (\(e.health?.source ?? "unknown source"))"
        case (_, .healthID?): return "Logged in Margin · same workout in Health"
        case (_, .timeOverlap?): return "Logged in Margin · matched to a Health workout by time"
        default: return "Logged in Margin only"
        }
    }
}
