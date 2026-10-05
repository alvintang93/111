import Charts
import SwiftUI
import MarginCore

/// Health metrics on iPhone: the same reports the watch computes, with more room for history.
struct PhoneHealthSection: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Section("Health metrics") {
            if let reports = model.brief?.healthMetrics {
                ForEach(reports) { r in
                    NavigationLink { PhoneMetricDetail(kind: r.kind) } label: {
                        HStack {
                            Label(r.kind.title, systemImage: r.kind.symbol)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(r.current.map { "\(r.kind.format($0.value)) \(r.kind.unitLabel)" } ?? "–").monospacedDigit()
                                Text(r.changeLine ?? r.state.label).font(.caption2)
                                    .foregroundStyle(r.changeLine == nil ? r.state.color : r.changeColor).lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                Text("Open Margin on your watch to send health metrics.").font(.footnote)
            }
        }
    }
}

struct PhoneMetricDetail: View {
    @EnvironmentObject private var model: PhoneModel
    let kind: HealthMetricKind

    var body: some View {
        List {
            if let r = model.brief?.healthMetrics?.first(where: { $0.kind == kind }) {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.kind.format(r.current?.value)).font(.system(size: 44, weight: .bold, design: .rounded))
                        if r.current != nil { Text(r.kind.unitLabel).foregroundStyle(.secondary) }
                    }
                    if let c = r.current {
                        Text("\(c.date.formatted(date: .abbreviated, time: .shortened))\(c.source.map { " · \($0)" } ?? "")\(c.count.map { " · \($0) readings" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let line = r.changeLine { Text(line).foregroundStyle(r.changeColor) }
                    if let z = r.z { Text(String(format: "%+.1f robust SD from your baseline", z)).font(.caption) }
                    Label(r.state.label, systemImage: r.state.symbol).foregroundStyle(r.state.color)
                    if !r.stateDetail.isEmpty { Text(r.stateDetail).font(.caption).foregroundStyle(.secondary) }
                }
                if r.history.count >= 2 {
                    Section("Trend") {
                        MetricChart(report: r).frame(height: 180)
                        ForEach(r.trends) { t in
                            LabeledContent("\(t.days) days",
                                           value: t.sufficient
                                           ? "\(t.change.map { "\(r.kind.formatSigned($0)) \(r.kind.unitLabel)" } ?? "–")\(t.slopePerWeek.map { " · \(r.kind.formatSigned($0))/wk" } ?? "")"
                                           : "\(t.n) of \(MetricMath.minimumCount(days: t.days, sporadic: !r.kind.hasRollingBaseline)) readings")
                        }
                    }
                }
                if !r.readings.isEmpty {
                    Section(r.kind == .hrv ? "Last night's readings" : "Latest readings") {
                        ForEach(r.readings) { o in ObservationRow(kind: r.kind, obs: o, showTime: true) }
                    }
                }
                Section("History") {
                    ForEach(r.history.reversed()) { o in ObservationRow(kind: r.kind, obs: o, showTime: !r.kind.hasRollingBaseline) }
                }
                Section("How it's measured") {
                    ForEach(r.notes, id: \.self) { Text($0).font(.caption) }
                    Text(r.methodology).font(.caption)
                    if let b = r.baseline { Text("Baseline: \(b.method), \(b.count) days.").font(.caption) }
                    if !r.sources.isEmpty { Text("Sources: \(r.sources.joined(separator: ", "))").font(.caption) }
                }
            }
        }
        .navigationTitle(kind.title)
    }
}

struct PhoneInsightsCard: View {
    let insights: [MetricPairInsight]

    var body: some View {
        Card(title: "Insights, 60 days") {
            ForEach(insights) { MetricPairRow(insight: $0) }
            Text("A fixed list of pairs, tested with Spearman's ρ and Holm-corrected. Needs \(MetricPairs.minimumN) days with both values. Associations, not causes.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct PhoneActivitiesView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        List {
            let entries = (model.brief?.activities ?? []).reversed()
            if entries.isEmpty { Text("No activities in the last 14 days.") }
            ForEach(Array(entries)) { e in
                NavigationLink { ScrollView { WorkoutAnalysisView(entry: e).padding() }.navigationTitle("Workout") } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.headline)
                    Text("\(e.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(e.end.timeIntervalSince(e.start) / 60)) min")
                        .font(.caption).foregroundStyle(.secondary)
                    if let h = e.health, let a = h.averageHR { Text(String(format: "avg HR %.0f · peak %.0f", a, h.peakHR ?? a)).font(.caption) }
                    Text(e.kind == .healthWorkout ? "From Health" : (e.health != nil ? "Logged in Margin · same Health workout" : "Logged in Margin"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                }
            }
        }
        .navigationTitle("Activities")
    }
}

struct PhoneRoutinesView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var editing: Routine?

    var body: some View {
        List {
            let lib = model.routines
            Button { editing = Routine(name: "", createdAt: Date()) } label: { Label("New routine", systemImage: "plus") }
            ForEach(lib.active) { r in
                Section {
                    ForEach(r.items) { i in Text(itemLine(i)) }
                    let history = RoutineRunner.history(r.id, log: model.payload?.strength ?? StrengthLog())
                    Text("\(history.count) session(s)\(history.last.map { ", last \($0.start.formatted(date: .abbreviated, time: .omitted))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Edit") { editing = r }
                        Spacer()
                        Button("Duplicate") { model.duplicateRoutine(r.id) }
                        Spacer()
                        Button("Delete", role: .destructive) { model.deleteRoutine(r.id) }
                    }
                    .buttonStyle(.borderless)
                } header: { Text(r.name) }
            }
            Text("Edits sync to your watch the next time it connects. Start routines on the watch.").font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Routines")
        .sheet(item: $editing) { r in PhoneRoutineEditor(routine: r) }
    }

    private func itemLine(_ i: RoutineItem) -> String {
        i.kind == .exercise
            ? "\(model.payload?.strength?.exercise(i.exerciseID ?? "")?.name ?? ExerciseLibrary.byID[i.exerciseID ?? ""]?.name ?? i.exerciseID ?? "") · \(i.sets) × \(i.reps)\(i.loadKg.map { String(format: " @ %g kg", $0) } ?? "")"
            : "\(WorkoutType.name(i.activityType ?? 0)) · \(i.minutes ?? 0) min"
    }
}

struct PhoneRoutineEditor: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $routine.name)
                Section("Items") {
                    ForEach($routine.items) { $item in
                        VStack(alignment: .leading) {
                            Text(item.kind == .exercise ? (ExerciseLibrary.byID[item.exerciseID ?? ""]?.name ?? item.exerciseID ?? "") : WorkoutType.name(item.activityType ?? 0))
                                .font(.headline)
                            if item.kind == .exercise {
                                Stepper("\(item.sets) sets", value: $item.sets, in: 1...10)
                                Stepper("\(item.reps) reps", value: $item.reps, in: 1...50)
                                Stepper("Rest \(item.restSeconds) s", value: $item.restSeconds, in: 0...600, step: 15)
                            } else {
                                Stepper("\(item.minutes ?? 10) min", value: Binding(get: { item.minutes ?? 10 }, set: { item.minutes = $0 }), in: 1...180)
                            }
                        }
                    }
                    .onMove { routine.items.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { routine.items.remove(atOffsets: $0) }
                }
                Section("Add exercise") {
                    TextField("Search", text: $search)
                    ForEach(ExerciseLibrary.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.prefix(search.isEmpty ? 0 : 12)) { e in
                        Button(e.name) { routine.items.append(.exercise(e.id)); search = "" }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(routine.name.isEmpty ? "New routine" : routine.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveRoutine(routine); dismiss() }
                        .disabled(routine.name.trimmingCharacters(in: .whitespaces).isEmpty || routine.items.isEmpty)
                }
            }
        }
    }
}
