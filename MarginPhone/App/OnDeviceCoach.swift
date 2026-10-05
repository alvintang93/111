// Builds with SDKs that predate FoundationModels (CI's Xcode); the private coach is then reported unavailable.
#if canImport(FoundationModels)
import Foundation
import FoundationModels
import MarginCore

/// The private coach: Apple's on-device language model (Apple Intelligence).
/// Free, needs no account, and nothing leaves the iPhone.
@available(iOS 26.0, *)
@MainActor
final class OnDeviceCoach {
    private var session: LanguageModelSession?

    static var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model. Try again in a while."
        case .unavailable: return "The on-device model isn't available right now."
        }
    }

    func reset() { session = nil }

    private func makeSession(instructions: String) -> LanguageModelSession {
        LanguageModelSession(tools: [TodayTool(), HistoryTool(), BodyTool(), StrengthTool(), LabsTool(), CalendarTool(),
                                     ChartTool(), PlanTool()],
                             instructions: instructions)
    }

    func respond(to prompt: String, instructions: String) async throws -> String {
        let s = session ?? makeSession(instructions: instructions)
        session = s
        do {
            return try await s.respond(to: prompt).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // The on-device context is small: start over and answer without the earlier turns.
            let fresh = makeSession(instructions: instructions)
            session = fresh
            let answer = try await fresh.respond(to: prompt).content
            return answer + "\n\n(Earlier messages no longer fit in the on-device model's memory, so I answered from scratch.)"
        }
    }

    static func instructions(personality: CoachPersonality) -> String {
        """
        You are the coach in Margin, a recovery and training app. You answer one person's questions about their own data. \
        \(personality.prompt) Always call a tool to get numbers before answering; never make up values. Recovery 0-100 \
        compares last night with the person's own baseline (50 = typical). Strain 0-100: 50 = a typical day's load. Muscles \
        are ready at freshness 80+. To plan sessions, call getCalendar, then proposePlan. To show a chart, call showChart. \
        You are not a clinician: do not identify or name medical conditions, and suggest a clinician for worrying results. \
        Keep answers short.
        """
    }
}

// MARK: - Tools (all read data Margin already computed)

@available(iOS 26.0, *)
private func brief() async -> DailyBrief? { await MainActor.run { PhoneModel.shared.brief } }

@available(iOS 26.0, *)
struct TodayTool: Tool {
    let name = "getToday"
    let description = "Get today's recovery score and components, directive, sleep, strain, stress, energy, training load, caffeine and water."

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await brief().map(CoachContext.today) ?? "No data from the watch yet. Ask the person to open Margin on their watch."
    }
}

@available(iOS 26.0, *)
struct HistoryTool: Tool {
    let name = "getMetricHistory"
    let description = "Get daily values of one metric for up to the last 30 days."

    @Generable struct Arguments {
        @Guide(description: "Metric name", .anyOf(["recovery", "hrv", "sleepingHR", "sleepHours", "sleepScore", "load", "stress", "steps", "caffeine", "water"]))
        var metric: String
        @Guide(description: "Number of days", .range(3...30))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        guard let m = CompareMetric(rawValue: arguments.metric) else { return "Unknown metric \(arguments.metric)." }
        return await brief().map { CoachContext.history($0, metric: m, days: arguments.days) } ?? "No data yet."
    }
}

@available(iOS 26.0, *)
struct BodyTool: Tool {
    let name = "getBody"
    let description = "Get body trends: biological age estimate, VO2 max, resting heart rate, body mass and fat, blood pressure, glucose, food, cycle and running."

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await brief().map(CoachContext.body) ?? "No data yet."
    }
}

@available(iOS 26.0, *)
struct StrengthTool: Tool {
    let name = "getStrength"
    let description = "Get muscle freshness, best estimated one-rep maxes and the last strength workout."

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await brief().map(CoachContext.strength) ?? "No data yet."
    }
}

@available(iOS 26.0, *)
struct LabsTool: Tool {
    let name = "getLabs"
    let description = "Get lab results the person entered, with the reference ranges from their reports."

    @Generable struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { CoachContext.labs(PhoneModel.shared.labs) }
    }
}

@available(iOS 26.0, *)
struct CalendarTool: Tool {
    let name = "getCalendar"
    let description = "Get busy times from the person's calendar for the coming days."

    @Generable struct Arguments {
        @Guide(description: "Number of days ahead", .range(1...7))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await CoachModel.shared.busyText(days: arguments.days)
    }
}

@available(iOS 26.0, *)
struct ChartTool: Tool {
    let name = "showChart"
    let description = "Show a chart in the chat of one or two daily metrics over the last 7-30 days."

    @Generable struct Arguments {
        var title: String
        @Guide(description: "First metric", .anyOf(["recovery", "hrv", "sleepingHR", "sleepHours", "sleepScore", "load", "stress", "steps", "caffeine", "water"]))
        var metric: String
        @Guide(description: "Optional second metric, or none", .anyOf(["none", "recovery", "hrv", "sleepingHR", "sleepHours", "sleepScore", "load", "stress", "steps", "caffeine", "water"]))
        var secondMetric: String
        @Guide(description: "Number of days", .range(7...30))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let metrics = [arguments.metric, arguments.secondMetric].compactMap(CompareMetric.init(rawValue:))
        guard !metrics.isEmpty else { return "No valid metric." }
        let chart = ChartRequest(title: arguments.title, metrics: metrics, days: arguments.days)
        await MainActor.run { CoachModel.shared.appendToolItem(ChatItem(kind: .chart, text: chart.title, chart: chart)) }
        return "The chart is shown to the person."
    }
}

@available(iOS 26.0, *)
struct PlanTool: Tool {
    let name = "proposePlan"
    let description = "Show proposed training sessions as cards the person can add to their calendar."

    @Generable struct Session {
        @Guide(description: "Local start time as yyyy-MM-ddTHH:mm, e.g. 2026-10-06T18:30")
        var start: String
        @Guide(description: "Duration in minutes", .range(10...240))
        var minutes: Int
        var title: String
        var notes: String
    }

    @Generable struct Arguments {
        @Guide(description: "Sessions to propose", .maximumCount(7))
        var sessions: [Session]
    }

    func call(arguments: Arguments) async throws -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let sessions = arguments.sessions.compactMap { s in
            f.date(from: String(s.start.prefix(16))).map { PlannedSession(start: $0, minutes: s.minutes, title: s.title, notes: s.notes) }
        }
        guard !sessions.isEmpty else { return "No valid start times. Use the format 2026-10-06T18:30." }
        await MainActor.run { CoachModel.shared.appendToolItem(ChatItem(kind: .plan, text: "Proposed plan", plan: sessions)) }
        return "\(sessions.count) session(s) are shown to the person."
    }
}
#endif
