import Charts
import SwiftUI
import MarginCore

struct CoachView: View {
    @EnvironmentObject private var coach: CoachModel
    @EnvironmentObject private var model: PhoneModel
    @State private var draft = ""

    private let starters = [
        "How recovered am I and what should I do today?",
        "Plan my training for the next 3 days around my calendar.",
        "Does caffeine affect my next-night HRV? Show a chart.",
        "Which muscles are ready to train?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !coach.hasKey {
                    ContentUnavailableView {
                        Label("Add your Claude API key", systemImage: "key")
                    } description: {
                        Text("The coach uses Claude through your own Anthropic API key, stored only in this iPhone's Keychain. When you chat, the numbers the coach looks up (scores, trends, labs, calendar busy times) are sent to Anthropic to answer you. Nothing is sent until you add a key and ask something.")
                    } actions: {
                        NavigationLink("Open coach settings") { Form { CoachSettingsSection() } }
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if coach.conversation.items.isEmpty {
                                    Text(coach.ghostMode ? "Ghost mode: this chat isn't saved." : "Ask about your recovery, training, sleep or habits.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    ForEach(starters, id: \.self) { s in
                                        Button(s) { Task { await coach.send(s) } }.buttonStyle(.bordered)
                                    }
                                }
                                ForEach(coach.conversation.items) { item in
                                    ChatBubble(item: item).id(item.id)
                                }
                                if coach.isWorking {
                                    HStack { ProgressView(); Text(coach.settings.mode == .thinking ? "Thinking…" : "Looking at your data…").foregroundStyle(.secondary) }
                                        .id("working")
                                }
                            }
                            .padding()
                        }
                        .onChange(of: coach.conversation.items.count) { _, _ in
                            withAnimation { proxy.scrollTo(coach.isWorking ? AnyHashable("working") : AnyHashable(coach.conversation.items.last?.id), anchor: .bottom) }
                        }
                    }
                    HStack(alignment: .bottom) {
                        TextField("Ask the coach", text: $draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...5)
                        Button {
                            let text = draft
                            draft = ""
                            Task { await coach.send(text) }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.title)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || coach.isWorking)
                    }
                    .padding()
                }
            }
            .navigationTitle(coach.ghostMode ? "Coach · ghost" : "Coach")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Mode", selection: $coach.settings.mode) {
                            ForEach(CoachMode.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Personality", selection: $coach.settings.personality) {
                            ForEach(CoachPersonality.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(coach.settings.mode.title, systemImage: "slider.horizontal.3")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { coach.setGhostMode(!coach.ghostMode) } label: {
                        Image(systemName: coach.ghostMode ? "theatermasks.fill" : "theatermasks")
                    }
                    .accessibilityLabel(coach.ghostMode ? "Leave ghost mode" : "Ghost mode")
                    Button { coach.newConversation() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .disabled(coach.ghostMode)
                }
            }
            .task(id: coach.pendingPrompt) {
                if let p = coach.pendingPrompt {
                    coach.pendingPrompt = nil
                    await coach.send(p)
                }
            }
        }
    }
}

struct ChatBubble: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var coach: CoachModel
    let item: ChatItem
    @State private var added: Set<UUID> = []
    @State private var calendarError: String?

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text).padding(10).background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            Text(LocalizedStringKey(item.text)).textSelection(.enabled)
        case .reasoning:
            DisclosureGroup("Reasoning summary") { Text(item.text).font(.caption).foregroundStyle(.secondary) }
                .font(.caption)
        case .toolNote:
            Text(item.text).font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .chart:
            if let c = item.chart { CoachChart(request: c, series: model.brief?.series ?? []) }
        case .plan:
            VStack(alignment: .leading, spacing: 8) {
                Text("Proposed sessions").font(.headline)
                ForEach(item.plan ?? []) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.title).font(.subheadline.weight(.semibold))
                            Text("\(s.start.formatted(date: .abbreviated, time: .shortened)) · \(s.minutes) min").font(.caption)
                            if !s.notes.isEmpty { Text(s.notes).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(added.contains(s.id) ? "Added" : "Add to Calendar") {
                            Task {
                                do {
                                    try await coach.addToCalendar(s)
                                    added.insert(s.id)
                                } catch {
                                    calendarError = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(added.contains(s.id))
                    }
                }
                if let calendarError { Text(calendarError).font(.caption).foregroundStyle(.orange) }
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Charts the coach asks for, drawn from the watch's daily series (values never come from the model).
struct CoachChart: View {
    let request: ChartRequest
    let series: [MetricSeries]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.title).font(.headline)
            let lines = request.metrics.compactMap { m in series.first { $0.metric == m } }
            if lines.isEmpty {
                Text("No data for these metrics yet.").font(.caption)
            } else {
                Chart {
                    ForEach(lines) { s in
                        let pts = Array(s.points.suffix(request.days))
                        let lo = pts.map(\.value).min() ?? 0, hi = pts.map(\.value).max() ?? 1
                        ForEach(pts) { p in
                            LineMark(x: .value("Day", p.day.date(hour: 12, calendar: .current), unit: .day),
                                     y: .value("Scaled", hi > lo ? (p.value - lo) / (hi - lo) : 0.5),
                                     series: .value("Metric", s.metric.title))
                                .foregroundStyle(by: .value("Metric", s.metric.title))
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 160)
                if lines.count == 2 {
                    let pairs = Correlation.pairs(lines[0], lines[1], lagDays: 0, calendar: .current)
                    if let r = Correlation.spearman(pairs.map(\.x), pairs.map(\.y)) {
                        Text(String(format: "Same-day Spearman ρ %+.2f (n = %d). Each line scaled to its own range.", r.rho, r.n))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CoachSettingsSection: View {
    @EnvironmentObject private var coach: CoachModel
    @State private var key = ""

    var body: some View {
        Section {
            if coach.hasKey {
                LabeledContent("API key", value: "Saved in Keychain")
                Button("Remove key", role: .destructive) { coach.setKey(nil) }
            } else {
                SecureField("Anthropic API key (sk-ant-…)", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    coach.setKey(key)
                    key = ""
                }
                .disabled(key.isEmpty)
            }
            Picker("Personality", selection: $coach.settings.personality) {
                ForEach(CoachPersonality.allCases) { Text($0.title).tag($0) }
            }
            Text(coach.settings.personality.blurb).font(.caption).foregroundStyle(.secondary)
            Picker("Mode", selection: $coach.settings.mode) {
                ForEach(CoachMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Share calendar event titles", isOn: $coach.settings.shareEventTitles)
        } header: {
            Text("Coach")
        } footer: {
            Text("Fast answers quickly with less reasoning, Thinking reasons longest and shows a summary, and Adaptive sits between them. Without event titles, the coach only sees when you're busy.")
        }
        Section("Check-ins") {
            ForEach($coach.settings.checkIns) { $c in
                VStack(alignment: .leading) {
                    Toggle(c.title, isOn: $c.enabled)
                    if c.enabled {
                        DatePicker("Time", selection: Binding(
                            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(c.minutes * 60)) },
                            set: { d in
                                let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
                                c.minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                            }), displayedComponents: .hourAndMinute)
                        if c.kind == .reminder { TextField("Reminder text", text: $c.body) }
                        Text(c.weekdays.isEmpty ? "Every day" : "Sundays").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
