import SwiftUI
import MarginCore

struct RoutinesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            NavigationLink {
                RoutineEditorView(routine: Routine(name: "", createdAt: Date()))
            } label: {
                Label("New routine", systemImage: "plus")
            }
            if model.routines.active.isEmpty {
                Text("Save a routine to start it in one tap, with weights filled in from last time.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.routines.active) { r in
                NavigationLink { RoutineDetailView(routineID: r.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).font(.footnote.weight(.semibold))
                        Text("\(r.items.count) item\(r.items.count == 1 ? "" : "s") · \(r.plannedSets) sets")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.routines.archived.isEmpty {
                Section("Archived") {
                    ForEach(model.routines.archived) { r in
                        NavigationLink(r.name) { RoutineDetailView(routineID: r.id) }
                    }
                }
            }
        }
        .navigationTitle("Routines")
    }
}

struct RoutineDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let routineID: UUID
    @State private var confirmDelete = false

    var body: some View {
        if let r = model.routines.routine(routineID) {
            List {
                NavigationLink {
                    ActiveStrengthView().task { await model.startStrengthWorkout(routine: r) }
                } label: {
                    Label("Start", systemImage: "play.fill").foregroundStyle(.green)
                }
                .disabled(model.activeSessionID != nil || model.activeActivity != nil || r.items.isEmpty)
                Section("Plan") {
                    ForEach(r.items) { item in RoutineItemSummary(item: item) }
                }
                let history = RoutineRunner.history(r.id, log: model.strength)
                Section("Previous sessions (\(history.count))") {
                    ForEach(history.reversed().prefix(10)) { s in
                        let p = RoutineRunner.progress(r, session: s, log: model.strength)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.start.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                            Text("\(s.sets.filter { !$0.warmup }.count) sets · \(Int((p.completedFraction * 100).rounded()))% of plan\(s.savedToHealth ? " · in Health" : "")")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    NavigationLink("Edit") { RoutineEditorView(routine: r) }
                    Button("Duplicate") { model.duplicateRoutine(r.id) }
                    Button(r.archived ? "Unarchive" : "Archive") { model.archiveRoutine(r.id, !r.archived) }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(r.name)
            .confirmationDialog("Delete \(r.name)? Past sessions and their sets are kept.", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteRoutine(r.id); dismiss() }
            }
        } else {
            Text("This routine was deleted.").font(.footnote)
        }
    }
}

struct RoutineItemSummary: View {
    @EnvironmentObject private var model: AppModel
    let item: RoutineItem

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch item.kind {
            case .exercise:
                Text(model.strength.exercise(item.exerciseID ?? "")?.name ?? item.exerciseID ?? "Exercise").font(.footnote)
                Text("\(item.sets) × \(item.reps)\(item.loadKg.map { " @ " + weight($0) } ?? " · last weight") · rest \(item.restSeconds)s")
                    .font(.caption2).foregroundStyle(.secondary)
            case .activity:
                Text(WorkoutType.name(item.activityType ?? 0)).font(.footnote)
                Text("\(item.minutes ?? 0) min").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func weight(_ kg: Double) -> String {
        let u = model.lifestyle.weightUnit
        return String(format: "%g %@", u.display(kg), u.rawValue)
    }
}

struct RoutineEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    @State private var picking = false
    @State private var addingActivity = false

    var body: some View {
        List {
            TextField("Name", text: $routine.name)
            Section("Items") {
                ForEach(Array(routine.items.enumerated()), id: \.element.id) { idx, item in
                    NavigationLink {
                        RoutineItemEditor(item: $routine.items[idx])
                    } label: {
                        RoutineItemSummary(item: item)
                    }
                    .swipeActions {
                        Button(role: .destructive) { routine.items.removeAll { $0.id == item.id } } label: { Label("Remove", systemImage: "trash") }
                        Button { move(item.id, -1) } label: { Label("Up", systemImage: "arrow.up") }
                        Button { move(item.id, 1) } label: { Label("Down", systemImage: "arrow.down") }
                    }
                }
                Button { picking = true } label: { Label("Add exercise", systemImage: "plus") }
                Button { addingActivity = true } label: { Label("Add timed activity", systemImage: "timer") }
            }
            Button("Save") {
                model.saveRoutine(routine)
                dismiss()
            }
            .glassButton(prominent: true)
            .disabled(routine.name.trimmingCharacters(in: .whitespaces).isEmpty || routine.items.isEmpty)
            Text("Swipe an item to reorder or remove it.").font(.caption2).foregroundStyle(.secondary)
        }
        .navigationTitle(routine.name.isEmpty ? "New routine" : "Edit")
        .sheet(isPresented: $picking) {
            ExercisePickerView { id in
                routine.items.append(.exercise(id, sets: 3, reps: 8, restSeconds: model.lifestyle.restSeconds))
                picking = false
            }
        }
        .sheet(isPresented: $addingActivity) {
            List {
                ForEach(ActivityCatalog.common.filter { !ActivityCatalog.strengthTypes.contains($0) }, id: \.self) { t in
                    Button(WorkoutType.name(t)) {
                        routine.items.append(.activity(t, minutes: 10))
                        addingActivity = false
                    }
                }
            }
        }
    }

    private func move(_ id: UUID, _ offset: Int) {
        guard let i = routine.items.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), routine.items.count - 1)
        guard i != j else { return }
        let item = routine.items.remove(at: i)
        routine.items.insert(item, at: j)
    }
}

struct RoutineItemEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var item: RoutineItem
    @State private var useLoad = false

    var body: some View {
        let u = model.lifestyle.weightUnit
        List {
            switch item.kind {
            case .exercise:
                Stepper("\(item.sets) sets", value: $item.sets, in: 1...10)
                Stepper("\(item.reps) reps", value: $item.reps, in: 1...50)
                Toggle("Fixed load", isOn: Binding(get: { item.loadKg != nil },
                                                   set: { item.loadKg = $0 ? (item.loadKg ?? model.strength.lastSet(of: item.exerciseID ?? "")?.weightKg ?? 20) : nil }))
                if let kg = item.loadKg {
                    Stepper(String(format: "%g %@", u.display(kg), u.rawValue),
                            value: Binding(get: { u.display(kg) }, set: { item.loadKg = u.toKg($0) }), in: 0...(u == .kg ? 400 : 900), step: u.step)
                } else {
                    Text("Uses what you lifted last time.").font(.caption2).foregroundStyle(.secondary)
                }
                Stepper("Rest \(item.restSeconds)s", value: $item.restSeconds, in: 0...600, step: 15)
            case .activity:
                Stepper("\(item.minutes ?? 10) min", value: Binding(get: { item.minutes ?? 10 }, set: { item.minutes = $0 }), in: 1...180)
            }
            TextField("Notes", text: $item.notes)
        }
        .navigationTitle(item.kind == .exercise ? (model.strength.exercise(item.exerciseID ?? "")?.name ?? "Exercise") : WorkoutType.name(item.activityType ?? 0))
    }
}

/// Shown at the top of an active strength workout started from a routine.
struct RoutineGuide: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (RoutineTarget) -> Void

    var body: some View {
        if let session = model.activeSession, let rid = session.routineID, let r = model.routines.routine(rid) {
            let p = RoutineRunner.progress(r, session: session, log: model.strength)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(r.name).font(.caption2.weight(.semibold))
                    Spacer()
                    Text("\(Int((p.completedFraction * 100).rounded()))%").font(.caption2).monospacedDigit()
                }
                ProgressView(value: p.completedFraction).tint(.green)
                if let next = p.next {
                    switch next.kind {
                    case .exercise:
                        Button { onSelect(next) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Next: \(model.strength.exercise(next.exerciseID ?? "")?.name ?? "") \(next.setNumber)/\(next.setCount)")
                                    .font(.caption2)
                                Text("\(next.reps) reps\(next.weightKg.map { String(format: " @ %g %@", model.lifestyle.weightUnit.display($0), model.lifestyle.weightUnit.rawValue) } ?? "")\(next.weightSource.map { " · \($0)" } ?? "")")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    case .activity:
                        Button("Done: \(WorkoutType.name(next.activityType ?? 0)) \(next.minutes ?? 0) min") {
                            model.completeRoutineItem(next.itemID)
                        }
                        .font(.caption2)
                    }
                } else {
                    Label("Routine complete", systemImage: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green)
                }
            }
            .padding(8)
            .glassCard(cornerRadius: 14, tint: .green)
        }
    }
}
