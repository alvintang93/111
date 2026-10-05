import EventKit
import Foundation
import MarginCore
import Security
import UserNotifications

// MARK: - Settings

enum CoachPersonality: String, Codable, CaseIterable, Identifiable {
    case coach, dataNerd, guardian

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coach: return "Coach"
        case .dataNerd: return "Data Nerd"
        case .guardian: return "Guardian"
        }
    }

    var blurb: String {
        switch self {
        case .coach: return "Direct and practical: what to do today and why."
        case .dataNerd: return "Deep technical analysis: numbers, baselines, methods and uncertainty."
        case .guardian: return "Balanced and long-term: sustainable habits, longevity, conservative calls."
        }
    }

    var prompt: String {
        switch self {
        case .coach:
            return "Voice: a direct, encouraging training coach. Lead with the recommendation for today, then the one or two numbers behind it. Keep it short."
        case .dataNerd:
            return "Voice: a quantitative sports scientist. Show the relevant numbers, baselines, z-scores, trends and how much data they rest on. Name uncertainty and alternative explanations. Tables are fine."
        case .guardian:
            return "Voice: a calm, long-term health guide. Favour sustainable habits, sleep and recovery over short-term performance, and err on the conservative side when signals conflict."
        }
    }
}

/// Fast / Adaptive / Thinking map onto the API's effort levels.
enum CoachMode: String, Codable, CaseIterable, Identifiable {
    case fast, adaptive, thinking

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var effort: String {
        switch self {
        case .fast: return "low"
        case .adaptive: return "medium"
        case .thinking: return "high"
        }
    }
}

/// Where the coach runs.
enum CoachEngine: String, Codable, CaseIterable, Identifiable {
    /// Apple Intelligence on this iPhone: free, nothing leaves the device.
    case onDevice
    /// Claude through your own Anthropic API key (paid, more capable).
    case claude

    var id: String { rawValue }
    var title: String { self == .onDevice ? "Private (on-device)" : "Claude (API key)" }
}

struct CoachSettings: Codable, Equatable {
    var engine: CoachEngine = .onDevice
    var personality: CoachPersonality = .coach
    var mode: CoachMode = .adaptive
    /// Calendar event titles are sent only when on; otherwise just busy times.
    var shareEventTitles = false
    var checkIns: [CheckIn] = CheckIn.defaults

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CoachSettings()
        engine = (try? c.decodeIfPresent(CoachEngine.self, forKey: .engine)) ?? d.engine
        personality = (try? c.decodeIfPresent(CoachPersonality.self, forKey: .personality)) ?? d.personality
        mode = (try? c.decodeIfPresent(CoachMode.self, forKey: .mode)) ?? d.mode
        shareEventTitles = (try? c.decodeIfPresent(Bool.self, forKey: .shareEventTitles)) ?? d.shareEventTitles
        checkIns = (try? c.decodeIfPresent([CheckIn].self, forKey: .checkIns)) ?? d.checkIns
    }
}

/// A scheduled nudge. Coach check-ins open the coach with a prompt when tapped.
struct CheckIn: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case coachPrompt, reminder }

    var id: UUID = UUID()
    var title: String
    var body: String
    var kind: Kind
    /// Minutes after midnight.
    var minutes: Int
    /// 1 = Sunday ... 7 = Saturday. Empty = every day.
    var weekdays: [Int]
    var enabled: Bool

    static let defaults: [CheckIn] = [
        CheckIn(title: "Morning recovery", body: "Give me my morning summary and what to do today.", kind: .coachPrompt,
                minutes: 7 * 60 + 30, weekdays: [], enabled: false),
        CheckIn(title: "Supplements", body: "Time for your supplements.", kind: .reminder, minutes: 8 * 60, weekdays: [], enabled: false),
        CheckIn(title: "Weekly review", body: "Review my week: recovery, load, sleep and strength, and set goals for next week.",
                kind: .coachPrompt, minutes: 18 * 60, weekdays: [1], enabled: false),
    ]
}

// MARK: - Chat model

struct ChatItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case user, assistant, reasoning, toolNote, chart, plan, error }

    var id = UUID()
    var kind: Kind
    var text: String
    var chart: ChartRequest?
    var plan: [PlannedSession]?
}

struct ChartRequest: Codable, Equatable {
    var title: String
    var metrics: [CompareMetric]
    var days: Int
}

struct PlannedSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Date
    var minutes: Int
    var title: String
    var notes: String
}

struct Conversation: Codable {
    /// Messages API history, sent back verbatim (append-only).
    var messages: [JSONValue] = []
    var items: [ChatItem] = []
}

enum CoachError: LocalizedError {
    case noKey, http(Int, String), refused, decode

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Anthropic API key in Settings to use the coach."
        case .http(let code, let message): return "Claude API error \(code): \(message)"
        case .refused: return "The model declined this request. Try rephrasing it."
        case .decode: return "Couldn't read the response."
        }
    }
}

@MainActor
final class CoachModel: ObservableObject {
    static let shared = CoachModel()

    static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxToolRounds = 8

    @Published var settings: CoachSettings {
        didSet {
            saveSettings()
            scheduleCheckIns()
            if settings.personality != oldValue.personality || settings.engine != oldValue.engine { resetOnDevice() }
        }
    }
    /// Held as AnyObject because the on-device coach needs iOS 26.
    private var onDeviceCoach: AnyObject?
    @Published private(set) var conversation = Conversation()
    @Published private(set) var isWorking = false
    @Published var ghostMode = false
    /// A check-in prompt to send when the Coach tab opens.
    @Published var pendingPrompt: String?
    @Published private(set) var hasKey: Bool

    private let calendar = EKEventStore()
    private static var conversationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("coach.json")
    }

    private init() {
        settings = (try? JSONDecoder().decode(CoachSettings.self, from: UserDefaults.standard.data(forKey: "coach.settings.v1") ?? Data()))
            ?? CoachSettings()
        hasKey = Keychain.read() != nil
        if let data = try? Data(contentsOf: Self.conversationURL), let c = try? JSONDecoder().decode(Conversation.self, from: data) {
            conversation = c
        }
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "coach.settings.v1") }
    }

    private func saveConversation() {
        guard !ghostMode else { return }
        try? FileManager.default.createDirectory(at: Self.conversationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(conversation).write(to: Self.conversationURL, options: .atomic)
    }

    func setKey(_ key: String?) {
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { Keychain.write(k) } else { Keychain.delete() }
        hasKey = Keychain.read() != nil
    }

    private func resetOnDevice() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { (onDeviceCoach as? OnDeviceCoach)?.reset() }
        #endif
    }

    /// Nil when the selected engine can be used now; otherwise what to do about it.
    var engineProblem: String? {
        switch settings.engine {
        case .claude: return hasKey ? nil : CoachError.noKey.localizedDescription
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { return OnDeviceCoach.availability }
            #endif
            return "The private coach needs iOS 26 or later."
        }
    }

    func appendToolItem(_ item: ChatItem) {
        conversation.items.append(item)
    }

    /// Ghost mode starts a fresh, unsaved conversation; leaving it restores the saved one.
    func setGhostMode(_ on: Bool) {
        resetOnDevice()
        ghostMode = on
        if on {
            conversation = Conversation()
        } else if let data = try? Data(contentsOf: Self.conversationURL), let c = try? JSONDecoder().decode(Conversation.self, from: data) {
            conversation = c
        } else {
            conversation = Conversation()
        }
    }

    func newConversation() {
        resetOnDevice()
        conversation = Conversation()
        saveConversation()
    }

    // MARK: Prompt

    var systemPrompt: String {
        """
        You are the coach inside Margin, a personal recovery and training app for Apple Watch. You help one person train, \
        recover and build habits using their own data. \(settings.personality.prompt)

        How Margin works: an overnight recovery score (HRV, sleeping heart rate, sleep vs need, respiration and wrist \
        temperature against 60-day personal baselines), a directive (push, maintain, recover, rest), training load as Banister \
        TRIMP with 7-day ATL and 42-day CTL, strain 0-100 where 50 is a typical day, rest-state heart-rate stress, an energy \
        bank, muscle freshness from logged strength sets, and biomarker trends read from Health. Use the tools to fetch numbers; \
        never invent values. If data is missing or still calibrating, say so.

        To show a chart, call show_chart. To suggest training sessions, call propose_plan with concrete times; check \
        get_calendar first so sessions avoid busy times. The person adds sessions to their calendar themselves.

        You are not a clinician. Do not identify or name medical conditions. For worrying symptoms, lab values outside the \
        reference range, or blood pressure concerns, suggest talking to a clinician. Keep replies short enough to read on a \
        phone unless asked for depth.
        """
    }

    // MARK: Tools

    static let tools: [JSONValue] = {
        let metricEnum: JSONValue = .array(CompareMetric.allCases.map { .string($0.rawValue) })
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
            .object([
                "name": .string(name), "description": .string(description),
                "input_schema": .object([
                    "type": "object", "properties": .object(properties),
                    "required": .array(required.map { .string($0) }), "additionalProperties": false,
                ]),
            ])
        }
        return [
            tool("get_today", "Today's scores: recovery and its components, directive and load targets, sleep, strain, stress, energy, caffeine and water, status flags and the timeline."),
            tool("get_metric_history", "Daily values of one metric for up to the last 30 days.",
                 ["metric": .object(["type": "string", "enum": metricEnum]),
                  "days": .object(["type": "integer", "minimum": 3, "maximum": 30])], required: ["metric"]),
            tool("get_body", "Biomarker trends (VO2 max, resting HR, body mass/fat/lean, blood pressure, glucose, nutrition), biological age estimate, cycle and running form."),
            tool("get_strength", "Muscle freshness and weekly sets, best estimated 1RMs and the last strength session."),
            tool("get_labs", "Lab results the person entered, with their report reference ranges."),
            tool("get_calendar", "Busy times from the person's calendar for the coming days.",
                 ["days": .object(["type": "integer", "minimum": 1, "maximum": 7])]),
            tool("show_chart", "Render a chart in the chat comparing up to two daily metrics.",
                 ["title": .object(["type": "string"]),
                  "metrics": .object(["type": "array", "items": .object(["type": "string", "enum": metricEnum]), "minItems": 1, "maxItems": 2]),
                  "days": .object(["type": "integer", "minimum": 7, "maximum": 30])], required: ["title", "metrics"]),
            tool("propose_plan", "Show proposed training sessions as cards the person can add to their calendar.",
                 ["sessions": .object(["type": "array", "maxItems": 14, "items": .object([
                    "type": "object", "additionalProperties": false,
                    "required": ["start", "minutes", "title"],
                    "properties": .object([
                        "start": .object(["type": "string", "description": "Local start time, ISO 8601 like 2026-10-06T18:30"]),
                        "minutes": .object(["type": "integer", "minimum": 10, "maximum": 240]),
                        "title": .object(["type": "string"]),
                        "notes": .object(["type": "string"]),
                    ]),
                 ])])], required: ["sessions"]),
        ]
    }()

    private func runTool(_ name: String, _ input: JSONValue) async -> (JSONValue, ChatItem?) {
        let phone = PhoneModel.shared
        guard let b = phone.brief else {
            return (["error": "No data from the watch yet. Ask the person to open Margin on their Apple Watch."], nil)
        }
        switch name {
        case "get_today":
            return ([
                "day": .string(b.day.description), "stale": .bool(!b.isCurrent()),
                "recovery": .from(b.recovery), "plan": .from(b.plan), "sleep": .from(b.sleep), "load": .from(b.load),
                "strain": .from(b.strain), "stress": .from(b.stress.map { s in ["score": s.score.map { JSONValue.number(Double($0)) } ?? .null,
                                                                               "current": s.current.map { .number(Double($0)) } ?? .null,
                                                                               "bandMinutes": .from(s.bandMinutes)] as JSONValue }),
                "energy": .from(b.energy.map { ["current": $0.current, "start": $0.start, "low": $0.low] }),
                "intake": .from(b.intake.map { ["caffeineNowMg": $0.caffeineNowMg, "caffeineAtBedtimeMg": $0.caffeineAtBedtimeMg,
                                                "waterTodayMl": $0.waterTodayMl, "waterTargetMl": $0.waterTargetMl] }),
                "statuses": .from(b.statuses ?? []), "timeline": .from(b.timelines?.last?.items ?? []),
                "profile": .from(["hrMax": b.hrMaxUsed, "hrRest": b.hrRestUsed]),
            ], nil)
        case "get_metric_history":
            let days = Int(input["days"]?.number ?? 14)
            guard let m = input["metric"]?.string.flatMap(CompareMetric.init(rawValue:)),
                  let s = b.series?.first(where: { $0.metric == m }) else { return (["error": "unknown metric"], nil) }
            return (.from(s.points.suffix(days).map { ["day": $0.day.description, "value": String(format: "%.2f", $0.value)] }), nil)
        case "get_body":
            return (.from(b.biomarkers), nil)
        case "get_strength":
            return (.from(b.strength), nil)
        case "get_labs":
            return (.from(phone.labs), nil)
        case "get_calendar":
            return (await busyTimes(days: Int(input["days"]?.number ?? 3)), nil)
        case "show_chart":
            let metrics = (input["metrics"]?.array ?? []).compactMap { $0.string.flatMap(CompareMetric.init(rawValue:)) }
            guard !metrics.isEmpty else { return (["error": "no valid metrics"], nil) }
            let chart = ChartRequest(title: input["title"]?.string ?? "Chart", metrics: Array(metrics.prefix(2)),
                                     days: Int(input["days"]?.number ?? 30))
            return (["shown": true], ChatItem(kind: .chart, text: chart.title, chart: chart))
        case "propose_plan":
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let sessions: [PlannedSession] = (input["sessions"]?.array ?? []).compactMap { s in
                guard let start = s["start"]?.string.flatMap({ f.date(from: String($0.prefix(16))) }),
                      let minutes = s["minutes"]?.number, let title = s["title"]?.string else { return nil }
                return PlannedSession(start: start, minutes: Int(minutes), title: title, notes: s["notes"]?.string ?? "")
            }
            guard !sessions.isEmpty else { return (["error": "no valid sessions; use start like 2026-10-06T18:30"], nil) }
            return (["shown": .number(Double(sessions.count))], ChatItem(kind: .plan, text: "Proposed plan", plan: sessions))
        default:
            return (["error": .string("unknown tool \(name)")], nil)
        }
    }

    // MARK: Calendar

    /// Busy times as short text, for the on-device coach.
    func busyText(days: Int) async -> String {
        let result = await busyTimes(days: days)
        guard let items = result.array else { return result["error"]?.string ?? "Calendar unavailable." }
        if items.isEmpty { return "No busy times in the next \(days) day(s)." }
        return "Busy: " + items.map { i in
            "\(i["start"]?.string ?? "?") to \(i["end"]?.string ?? "?")\(i["allDay"]?.bool == true ? " (all day)" : "")\(i["title"]?.string.map { " " + $0 } ?? "")"
        }.joined(separator: "; ")
    }

    private func busyTimes(days: Int) async -> JSONValue {
        do {
            guard try await calendar.requestFullAccessToEvents() else { return ["error": "Calendar access not granted."] }
        } catch {
            return ["error": .string(error.localizedDescription)]
        }
        let start = Date(), end = start.addingTimeInterval(Double(max(1, min(days, 7))) * 86400)
        let events = calendar.events(matching: calendar.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { $0.availability != .free }
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return .array(events.map { e in
            var o: [String: JSONValue] = ["start": .string(f.string(from: e.startDate)), "end": .string(f.string(from: e.endDate)),
                                          "allDay": .bool(e.isAllDay)]
            if settings.shareEventTitles, let t = e.title { o["title"] = .string(t) }
            return .object(o)
        })
    }

    func addToCalendar(_ s: PlannedSession) async throws {
        guard try await calendar.requestFullAccessToEvents() else { throw CoachError.http(0, "Calendar access not granted") }
        let e = EKEvent(eventStore: calendar)
        e.title = s.title
        e.notes = s.notes.isEmpty ? "Planned with Margin" : s.notes
        e.startDate = s.start
        e.endDate = s.start.addingTimeInterval(Double(s.minutes) * 60)
        e.calendar = calendar.defaultCalendarForNewEvents
        try calendar.save(e, span: .thisEvent)
    }

    // MARK: Conversation loop

    func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isWorking else { return }
        if settings.engine == .onDevice {
            await sendOnDevice(prompt)
            return
        }
        guard let key = Keychain.read() else {
            conversation.items.append(ChatItem(kind: .error, text: CoachError.noKey.localizedDescription))
            return
        }
        isWorking = true
        defer { isWorking = false; saveConversation() }
        let stamp = Date().formatted(.dateTime.weekday(.wide).day().month().year().hour().minute())
        let checkpoint = conversation.messages.count
        conversation.items.append(ChatItem(kind: .user, text: prompt))
        conversation.messages.append(["role": "user", "content": .array([
            ["type": "text", "text": .string("[\(stamp)] \(prompt)")],
        ])])
        do {
            for _ in 0..<Self.maxToolRounds {
                let response = try await request(key: key)
                let content = response["content"]?.array ?? []
                // Append the assistant turn unchanged so thinking blocks stay valid.
                conversation.messages.append(["role": "assistant", "content": .array(content)])
                for block in content {
                    switch block["type"]?.string {
                    case "text":
                        if let t = block["text"]?.string, !t.isEmpty { conversation.items.append(ChatItem(kind: .assistant, text: t)) }
                    case "thinking":
                        if settings.mode == .thinking, let t = block["thinking"]?.string, !t.isEmpty {
                            conversation.items.append(ChatItem(kind: .reasoning, text: t))
                        }
                    default: break
                    }
                }
                let stop = response["stop_reason"]?.string
                if stop == "refusal" { throw CoachError.refused }
                guard stop == "tool_use" else {
                    if stop == "max_tokens" { conversation.items.append(ChatItem(kind: .error, text: "The reply was cut off. Ask me to continue.")) }
                    return
                }
                var results: [JSONValue] = []
                for block in content where block["type"]?.string == "tool_use" {
                    guard let id = block["id"]?.string, let name = block["name"]?.string else { continue }
                    let (result, item) = await runTool(name, block["input"] ?? [:])
                    if let item { conversation.items.append(item) }
                    var r: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(result.jsonText)]
                    if result["error"] != nil { r["is_error"] = true }
                    results.append(.object(r))
                }
                // All results for one assistant turn go back in a single user message.
                conversation.messages.append(["role": "user", "content": .array(results)])
            }
            conversation.items.append(ChatItem(kind: .error, text: "Stopped after \(Self.maxToolRounds) tool rounds."))
        } catch {
            conversation.items.append(ChatItem(kind: .error, text: error.localizedDescription))
            // Drop this whole exchange (only appended messages, so the earlier history is untouched).
            conversation.messages.removeSubrange(checkpoint...)
        }
    }

    private func sendOnDevice(_ prompt: String) async {
        #if !canImport(FoundationModels)
        conversation.items.append(ChatItem(kind: .error, text: "The private coach needs iOS 26 or later."))
        #else
        guard #available(iOS 26.0, *) else {
            conversation.items.append(ChatItem(kind: .error, text: "The private coach needs iOS 26 or later."))
            return
        }
        if let problem = OnDeviceCoach.availability {
            conversation.items.append(ChatItem(kind: .error, text: problem))
            return
        }
        isWorking = true
        defer { isWorking = false; saveConversation() }
        conversation.items.append(ChatItem(kind: .user, text: prompt))
        let coach = (onDeviceCoach as? OnDeviceCoach) ?? OnDeviceCoach()
        onDeviceCoach = coach
        let stamp = Date().formatted(.dateTime.weekday(.wide).day().month().year().hour().minute())
        do {
            let answer = try await coach.respond(to: "[\(stamp)] \(prompt)",
                                                 instructions: OnDeviceCoach.instructions(personality: settings.personality))
            conversation.items.append(ChatItem(kind: .assistant, text: answer))
        } catch {
            coach.reset()
            conversation.items.append(ChatItem(kind: .error, text: "The on-device model couldn't answer: \(error.localizedDescription)"))
        }
        #endif
    }

    private func request(key: String) async throws -> JSONValue {
        var thinking: [String: JSONValue] = ["type": "adaptive"]
        if settings.mode == .thinking { thinking["display"] = "summarized" }
        let body: JSONValue = .object([
            "model": .string(Self.model),
            "max_tokens": 16000,
            "system": .array([["type": "text", "text": .string(systemPrompt), "cache_control": ["type": "ephemeral"]]]),
            "tools": .array(Self.tools),
            "thinking": .object(thinking),
            "output_config": ["effort": .string(settings.mode.effort)],
            "fallbacks": "default",
            "messages": .array(conversation.messages),
        ])
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONEncoder().encode(body)

        var attempt = 0
        while true {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw CoachError.decode }
                return v
            }
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?["message"]?.string ?? "HTTP \(code)"
            // Retry rate limits and overload/server errors twice with backoff; everything else is final.
            if (code == 429 || code >= 500) && attempt < 2 {
                attempt += 1
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? pow(2, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
                continue
            }
            throw CoachError.http(code, code == 401 ? "The API key was rejected. Check it in Settings." : message)
        }
    }

    // MARK: Check-ins

    func scheduleCheckIns() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix("coach-checkin-") }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: old)
        }
        let enabled = settings.checkIns.filter(\.enabled)
        guard !enabled.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for c in enabled {
                let content = UNMutableNotificationContent()
                content.title = c.title
                content.body = c.kind == .coachPrompt ? "Tap to ask the coach." : c.body
                content.sound = .default
                if c.kind == .coachPrompt { content.userInfo = ["coachPrompt": c.body] }
                let days = c.weekdays.isEmpty ? [nil] : c.weekdays.map { Optional($0) }
                for (k, day) in days.enumerated() {
                    var comps = DateComponents()
                    comps.hour = c.minutes / 60
                    comps.minute = c.minutes % 60
                    comps.weekday = day
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "coach-checkin-\(c.id)-\(k)", content: content,
                                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
                }
            }
        }
    }
}

// MARK: - Keychain

/// The API key lives only in this iPhone's Keychain.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "margin.anthropic",
        kSecAttrAccount as String: "api-key",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Routes a tapped coach check-in into the Coach tab.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let prompt = response.notification.request.content.userInfo["coachPrompt"] as? String else { return }
        await MainActor.run { CoachModel.shared.pendingPrompt = prompt }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
