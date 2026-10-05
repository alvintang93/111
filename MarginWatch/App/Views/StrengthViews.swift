import SwiftUI
import MarginCore

// MARK: - Home

struct StrengthHomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if model.activeSessionID != nil {
                NavigationLink {
                    ActiveStrengthView()
                } label: {
                    Label("Resume workout", systemImage: "figure.strengthtraining.traditional").foregroundStyle(.green)
                }
            } else {
                NavigationLink {
                    ActiveStrengthView()
                        .task { await model.startStrengthWorkout() }
                } label: {
                    Label("Start workout", systemImage: "play.fill").foregroundStyle(.green)
                }
            }
            if let st = model.brief?.strength, model.brief?.isCurrent() == true {
                Section("Muscles") {
                    NavigationLink {
                        MuscleMapView(summary: st)
                    } label: {
                        MuscleMapFigure(muscles: st.muscles).frame(height: 120)
                    }
                }
                if let last = st.lastSession {
                    Section("Last workout") {
                        MetricRow(label: last.start.formatted(date: .abbreviated, time: .shortened), value: "\(last.sets) sets")
                        MetricRow(label: "Volume", value: weight(last.volumeKg))
                        Text(last.exercises.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                        if !last.newRecords.isEmpty {
                            Label("Record: \(last.newRecords.joined(separator: ", "))", systemImage: "trophy.fill")
                                .font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                }
                Section("Best estimated 1RM") {
                    ForEach(st.records.prefix(8)) { r in
                        NavigationLink {
                            ExerciseHistoryView(exerciseID: r.exerciseID)
                        } label: {
                            MetricRow(label: r.name, value: weight(r.e1RM))
                        }
                    }
                }
            } else {
                Text("Log a workout to see muscle freshness, weekly sets and records.").font(.footnote)
            }
            Section {
                NavigationLink { PlateCalculatorView() } label: { Label("Plate calculator", systemImage: "circle.grid.cross") }
                NavigationLink { ExerciseLibraryView() } label: { Label("Exercises", systemImage: "books.vertical") }
                NavigationLink { StrengthHistoryView() } label: { Label("History", systemImage: "clock") }
            }
        }
        .navigationTitle("Strength")
    }

    private func weight(_ kg: Double) -> String {
        let u = model.lifestyle.weightUnit
        return String(format: "%.0f %@", u.display(kg), u.rawValue)
    }
}

// MARK: - Active workout

struct ActiveStrengthView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var workout = AppModel.shared.strengthWorkout
    @State private var exerciseID: String?
    @State private var weight = 20.0
    @State private var reps = 8
    @State private var rpe = 8.0
    @State private var useRPE = false
    @State private var warmup = false
    @State private var picking = false
    @State private var confirmEnd = false
    @State private var deleting: StrengthSet?
    @Environment(\.dismiss) private var dismiss

    private var unit: WeightUnit { model.lifestyle.weightUnit }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                RoutineGuide { target in applyTarget(target) }
                if let id = exerciseID, let ex = model.strength.exercise(id) {
                    Button { picking = true } label: {
                        HStack {
                            Text(ex.name).font(.headline).lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if let last = model.strength.lastSet(of: id) {
                        Text("Last: \(fmt(last.weightKg)) × \(last.reps)").font(.caption2).foregroundStyle(.secondary)
                    }
                    weightControl(ex)
                    Stepper("\(reps) reps", value: $reps, in: 1...50)
                    Toggle("RPE", isOn: $useRPE)
                    if useRPE {
                        Stepper(String(format: "RPE %.1f", rpe), value: $rpe, in: 5...10, step: 0.5)
                    }
                    Toggle("Warm-up", isOn: $warmup)
                    Button {
                        model.logSet(exerciseID: id, weightKg: unit.toKg(weight), reps: reps, rpe: useRPE ? rpe : nil, warmup: warmup)
                        warmup = false
                    } label: {
                        Label("Log set", systemImage: "checkmark.circle.fill")
                    }
                    .tint(.green)
                    .glassButton(prominent: true)
                    .modifier(PrimaryDoubleTap())
                } else {
                    Button("Choose exercise") { picking = true }.tint(.green)
                }
                if let session = model.activeSession, !session.sets.isEmpty {
                    SectionHeader(text: "This workout")
                    ForEach(session.sets.reversed()) { s in
                        Button { deleting = s } label: {
                            HStack {
                                Text(model.strength.exercise(s.exerciseID)?.name ?? s.exerciseID).font(.caption2).lineLimit(1)
                                Spacer()
                                Text("\(fmt(s.weightKg)) × \(s.reps)\(s.warmup ? " w" : "")").font(.caption2).monospacedDigit()
                            }
                            .foregroundStyle(s.warmup ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("End workout", role: .destructive) { confirmEnd = true }
                    .disabled(model.activeSessionID == nil)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Workout")
        .sheet(isPresented: $picking) {
            ExercisePickerView { id in
                select(id)
                picking = false
            }
        }
        .confirmationDialog("End this workout?", isPresented: $confirmEnd) {
            Button("Save to Health") { Task { await model.endStrengthWorkout(save: true); dismiss() } }
            Button("Discard", role: .destructive) { Task { await model.endStrengthWorkout(save: false); dismiss() } }
        }
        .confirmationDialog("Delete this set?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = deleting { model.deleteSet(s.id) }
                deleting = nil
            }
        }
        .onAppear {
            if exerciseID == nil, let session = model.activeSession, let rid = session.routineID,
               let r = model.routines.routine(rid), let next = RoutineRunner.progress(r, session: session, log: model.strength).next,
               next.kind == .exercise {
                applyTarget(next)
            } else if exerciseID == nil, let recent = model.strength.recentExerciseIDs(limit: 1).first {
                select(recent)
            }
        }
        .onChange(of: model.activeSession?.sets.count) { _, _ in
            // After a set, move to the routine's next planned set.
            if let session = model.activeSession, let rid = session.routineID, let r = model.routines.routine(rid),
               let next = RoutineRunner.progress(r, session: session, log: model.strength).next, next.kind == .exercise {
                applyTarget(next)
            }
        }
    }

    private func applyTarget(_ t: RoutineTarget) {
        guard let ex = t.exerciseID else { return }
        exerciseID = ex
        reps = t.reps
        if let kg = t.weightKg {
            weight = (unit.display(kg) / unit.step).rounded() * unit.step
        } else {
            select(ex)
            reps = t.reps
        }
    }

    private var header: some View {
        HStack {
            if let start = workout.startDate {
                Text(start, style: .timer).font(.title3.monospacedDigit())
            }
            Spacer()
            if let hr = workout.heartRate {
                Label("\(Int(hr))", systemImage: "heart.fill").foregroundStyle(.red).font(.footnote.monospacedDigit())
            }
        }
        .overlay(alignment: .bottom) {
            if let rest = workout.restEndsAt {
                HStack {
                    Text("Rest").foregroundStyle(.secondary)
                    Text(rest, style: .timer).monospacedDigit()
                    Button { workout.cancelRest() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                }
                .font(.caption2)
                .offset(y: 16)
            }
        }
        .padding(.bottom, workout.restEndsAt == nil ? 0 : 16)
    }

    private func weightControl(_ ex: Exercise) -> some View {
        VStack(spacing: 2) {
            Text(ex.bodyweightFactor > 0 ? "+\(fmtDisplay(weight)) \(unit.rawValue) added" : "\(fmtDisplay(weight)) \(unit.rawValue)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .focusable()
                .digitalCrownRotation($weight, from: 0, through: unit == .kg ? 400 : 900, by: unit.step,
                                      sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
            HStack {
                Button { weight = max(0, weight - unit.step) } label: { Image(systemName: "minus") }
                Button { weight += unit.step } label: { Image(systemName: "plus") }
            }
            if ex.equipment == .barbell {
                let load = PlateCalculator.load(target: weight, bar: unit.display(model.lifestyle.barWeightKg), plates: unit.plates)
                Text("Per side: \(load.perSide.isEmpty ? "bar only" : load.perSide.map { fmtPlate($0) }.joined(separator: " + "))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .glassCard(cornerRadius: 18)
    }

    private func select(_ id: String) {
        exerciseID = id
        if let last = model.strength.lastSet(of: id) {
            weight = (unit.display(last.weightKg) / unit.step).rounded() * unit.step
            reps = last.reps
        } else if model.strength.exercise(id)?.bodyweightFactor ?? 0 > 0 {
            weight = 0
        }
    }

    private func fmt(_ kg: Double) -> String { "\(fmtDisplay(unit.display(kg))) \(unit.rawValue)" }
    private func fmtDisplay(_ v: Double) -> String { v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
    private func fmtPlate(_ v: Double) -> String { v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.2g", v) }
}

// MARK: - Picker and library

struct ExercisePickerView: View {
    @EnvironmentObject private var model: AppModel
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                let recent = model.strength.recentExerciseIDs()
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent, id: \.self) { id in
                            Button(model.strength.exercise(id)?.name ?? id) { onPick(id) }
                        }
                    }
                }
                if !model.strength.customExercises.isEmpty {
                    Section("Yours") {
                        ForEach(model.strength.customExercises) { e in Button(e.name) { onPick(e.id) } }
                    }
                }
                Section("By muscle") {
                    ForEach(Muscle.allCases, id: \.self) { m in
                        NavigationLink(m.title) {
                            List(ExerciseLibrary.exercises(for: m)) { e in
                                Button(e.name) { onPick(e.id) }
                            }
                            .navigationTitle(m.title)
                        }
                    }
                }
                NavigationLink("New exercise") { CustomExerciseView() }
            }
            .navigationTitle("Exercise")
        }
    }
}

struct ExerciseLibraryView: View {
    var body: some View {
        List {
            ForEach(Muscle.allCases, id: \.self) { m in
                NavigationLink("\(m.title) (\(ExerciseLibrary.exercises(for: m).count))") {
                    List(ExerciseLibrary.exercises(for: m)) { e in
                        NavigationLink {
                            ExerciseHistoryView(exerciseID: e.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name).font(.footnote)
                                Text(([e.equipment.rawValue] + e.secondary.map(\.title)).joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle(m.title)
                }
            }
        }
        .navigationTitle("Exercises")
    }
}

struct CustomExerciseView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var primary: Muscle = .chest
    @State private var equipment: Equipment = .dumbbell

    var body: some View {
        List {
            TextField("Name", text: $name)
            Picker("Main muscle", selection: $primary) { ForEach(Muscle.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Equipment", selection: $equipment) { ForEach(Equipment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Button("Add") {
                model.addCustomExercise(name: name.trimmingCharacters(in: .whitespaces), primary: primary, secondary: [], equipment: equipment)
                dismiss()
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle("New exercise")
    }
}

struct ExerciseHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let exerciseID: String

    var body: some View {
        let sets = model.strength.workingSets.filter { $0.exerciseID == exerciseID }
        let u = model.lifestyle.weightUnit
        List {
            if let ex = model.strength.exercise(exerciseID) {
                Text("Works \(ex.primary.map(\.title).joined(separator: ", "))" + (ex.secondary.isEmpty ? "" : "; also \(ex.secondary.map(\.title).joined(separator: ", "))"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if sets.isEmpty {
                Text("Not logged yet.").font(.footnote)
            } else {
                let best = sets.max { StrengthModel.e1RM(weightKg: $0.weightKg, reps: $0.reps) < StrengthModel.e1RM(weightKg: $1.weightKg, reps: $1.reps) }!
                MetricRow(label: "Best e1RM", value: String(format: "%.0f %@", u.display(StrengthModel.e1RM(weightKg: best.weightKg, reps: best.reps)), u.rawValue))
                ForEach(sets.reversed().prefix(30)) { s in
                    HStack {
                        Text(s.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f × %d", u.display(s.weightKg), s.reps)).monospacedDigit()
                    }
                    .font(.footnote)
                }
            }
        }
        .navigationTitle(model.strength.exercise(exerciseID)?.name ?? "Exercise")
    }
}

struct StrengthHistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            let sessions = model.strength.sessions.filter { !$0.sets.isEmpty }.reversed()
            if sessions.isEmpty { Text("No workouts yet.").font(.footnote) }
            ForEach(Array(sessions)) { s in
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.start.formatted(date: .abbreviated, time: .shortened)).font(.footnote.weight(.semibold))
                    Text("\(s.sets.filter { !$0.warmup }.count) sets\(s.savedToHealth ? " · in Health" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions { Button(role: .destructive) { model.deleteSession(s.id) } label: { Label("Delete", systemImage: "trash") } }
            }
        }
        .navigationTitle("History")
    }
}

// MARK: - Plate calculator

struct PlateCalculatorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var target = 100.0

    var body: some View {
        let u = model.lifestyle.weightUnit
        let bar = u.display(model.lifestyle.barWeightKg)
        let load = PlateCalculator.load(target: target, bar: bar, plates: u.plates)
        ScrollView {
            VStack(spacing: 8) {
                Text(String(format: "%.1f %@", target, u.rawValue))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .focusable()
                    .digitalCrownRotation($target, from: bar, through: u == .kg ? 400 : 900, by: u.step,
                                          sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                HStack(alignment: .center, spacing: 2) {
                    Rectangle().fill(.gray).frame(width: 30, height: 6)
                    ForEach(Array(load.perSide.enumerated()), id: \.offset) { _, p in
                        RoundedRectangle(cornerRadius: 2).fill(color(p, u))
                            .frame(width: 8, height: 20 + CGFloat(p / u.plates[0]) * 40)
                    }
                }
                Text(load.perSide.isEmpty ? "Bar only" : "Per side: " + load.perSide.map { String(format: "%g", $0) }.joined(separator: " + "))
                    .font(.footnote)
                if !load.exact {
                    Text(String(format: "Closest: %.2f %@", load.achieved, u.rawValue)).font(.caption2).foregroundStyle(.orange)
                }
                Stepper(String(format: "Bar %.1f %@", bar, u.rawValue), value: Binding(
                    get: { model.lifestyle.barWeightKg },
                    set: { model.lifestyle.barWeightKg = $0 }
                ), in: 5...25, step: u == .kg ? 2.5 : WeightUnit.kgPerLb * 5)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Plates")
    }

    private func color(_ p: Double, _ u: WeightUnit) -> Color {
        let colors: [Color] = [.red, .blue, .yellow, .green, .white, .gray, .orange]
        return colors[min(u.plates.firstIndex(of: p) ?? 0, colors.count - 1)]
    }
}

// MARK: - Muscle map

/// Front and back silhouettes with each muscle group coloured by freshness.
struct MuscleMapFigure: View {
    let muscles: [MuscleStatus]

    private func fill(_ m: Muscle) -> Color {
        guard let s = muscles.first(where: { $0.muscle == m }) else { return .gray.opacity(0.3) }
        switch Double(s.freshness) {
        case StrengthModel.readyFreshness...: return .green.opacity(0.75)
        case 50..<StrengthModel.readyFreshness: return .yellow.opacity(0.85)
        default: return .red.opacity(0.85)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 2, h = geo.size.height
            HStack(spacing: 0) {
                figure(front: true, w: w, h: h)
                figure(front: false, w: w, h: h)
            }
        }
        .accessibilityLabel("Muscle freshness map")
    }

    /// Shapes in a 100 × 200 design space, scaled to the available size.
    private func figure(front: Bool, w: CGFloat, h: CGFloat) -> some View {
        let sx = w / 100, sy = h / 200
        func part(_ m: Muscle?, _ x: CGFloat, _ y: CGFloat, _ pw: CGFloat, _ ph: CGFloat, mirrored: Bool = true) -> some View {
            ZStack {
                ForEach(mirrored ? [x, 100 - x] : [x], id: \.self) { cx in
                    Capsule().fill(m.map(fill) ?? Color.white.opacity(0.15))
                        .frame(width: pw * sx, height: ph * sy)
                        .position(x: cx * sx, y: y * sy)
                }
            }
        }
        return ZStack {
            Circle().fill(Color.white.opacity(0.15)).frame(width: 18 * sx, height: 18 * sx).position(x: 50 * sx, y: 14 * sy)
            if front {
                part(.frontDelts, 30, 40, 12, 14)
                part(.chest, 41, 48, 18, 18)
                part(.biceps, 24, 64, 9, 24)
                part(.forearms, 21, 92, 8, 26)
                part(.abs, 50, 78, 16, 36, mirrored: false)
                part(.obliques, 38, 82, 6, 26)
                part(.quads, 41, 128, 15, 44)
                part(.calves, 41, 172, 9, 30)
                part(.sideDelts, 24, 42, 6, 12)
            } else {
                part(.upperBack, 50, 44, 26, 18, mirrored: false)
                part(.rearDelts, 29, 40, 10, 12)
                part(.lats, 38, 66, 12, 30)
                part(.triceps, 24, 64, 9, 24)
                part(.forearms, 21, 92, 8, 26)
                part(.lowerBack, 50, 90, 14, 18, mirrored: false)
                part(.glutes, 42, 108, 16, 18)
                part(.hamstrings, 41, 136, 14, 36)
                part(.calves, 41, 172, 10, 30)
            }
        }
        .frame(width: w, height: h)
    }
}

struct MuscleMapView: View {
    let summary: StrengthSummary

    var body: some View {
        List {
            MuscleMapFigure(muscles: summary.muscles).frame(height: 160)
            HStack(spacing: 8) {
                Label("Ready", systemImage: "circle.fill").foregroundStyle(.green)
                Label("Recovering", systemImage: "circle.fill").foregroundStyle(.yellow)
                Label("Fatigued", systemImage: "circle.fill").foregroundStyle(.red)
            }
            .font(.system(size: 9))
            ForEach(summary.muscles.sorted { $0.freshness < $1.freshness }) { m in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(m.muscle.title).font(.footnote.weight(.semibold))
                        Spacer()
                        Text("\(m.freshness)").font(.footnote.monospacedDigit())
                    }
                    HStack {
                        Text(String(format: "%.1f sets this week", m.weeklySets))
                        Spacer()
                        if let r = m.readyAt {
                            Text("ready \(r.formatted(.dateTime.weekday(.abbreviated).hour()))")
                        } else {
                            Text("ready")
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Freshness falls with hard sets (main muscles count 1, helpers ½, scaled by RPE when entered) and recovers over about a day for small muscles and a day and a half for large ones. Weekly sets: most people grow on 10–20 per muscle.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .navigationTitle("Muscles")
    }
}

// MARK: - Settings

struct StrengthSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Strength") {
            Picker("Units", selection: $model.lifestyle.weightUnit) {
                Text("kg").tag(WeightUnit.kg)
                Text("lb").tag(WeightUnit.lb)
            }
            Stepper("Rest \(model.lifestyle.restSeconds / 60):\(String(format: "%02d", model.lifestyle.restSeconds % 60))",
                    value: $model.lifestyle.restSeconds, in: 30...300, step: 15)
            Picker("Top lift tile", selection: Binding(
                get: { model.lifestyle.pinnedLiftID ?? "" },
                set: { model.lifestyle.pinnedLiftID = $0.isEmpty ? nil : $0 }
            )) {
                Text("None").tag("")
                ForEach(["bench-press", "back-squat", "deadlift", "overhead-press", "pull-up", "barbell-row"], id: \.self) { id in
                    Text(ExerciseLibrary.byID[id]?.name ?? id).tag(id)
                }
            }
        }
    }
}
