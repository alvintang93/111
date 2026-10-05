import Foundation
import MarginCore
import UserNotifications

/// Local check-in notifications. Re-evaluated after every rescore, so each one
/// reflects the latest brief. Nothing leaves the watch.
@MainActor
final class CheckInScheduler {
    private enum ID {
        static let journal = "checkin-journal"
        static let caffeine = "checkin-caffeine-cutoff"
    }

    private var center: UNUserNotificationCenter { .current() }

    func update(brief b: DailyBrief, settings: CheckInSettings, journaledToday: Bool, now: Date, prefs: Preferences) {
        let cal = Calendar.current
        guard b.isCurrent(now: now, calendar: cal) else { return }
        morningSummary(b, enabled: settings.morningSummary, now: now, prefs: prefs)
        scheduleJournalReminder(enabled: settings.eveningJournal, minutes: settings.eveningJournalMinutes,
                                journaledToday: journaledToday, now: now, calendar: cal)
        scheduleCaffeineCutoff(b, enabled: settings.caffeineCutoff, now: now)
        weeklyReview(b, enabled: settings.weeklyReview, now: now, calendar: cal, prefs: prefs)
    }

    /// Sent once, the first time a brief is computed at least 30 minutes after waking (before 14:00).
    private func morningSummary(_ b: DailyBrief, enabled: Bool, now: Date, prefs: Preferences) {
        guard enabled, prefs.lastMorningSummaryDay != b.day.description, let sleep = b.sleep,
              b.recovery.status != .nightInProgress, now >= sleep.wake.addingTimeInterval(30 * 60),
              Calendar.current.component(.hour, from: now) < 14 else { return }
        prefs.lastMorningSummaryDay = b.day.description
        var parts: [String] = []
        if let s = b.recovery.score {
            parts.append("Recovery \(s) · \(b.plan.directive.title.capitalized).")
        } else {
            parts.append(b.recovery.statusDetail)
        }
        parts.append("Sleep \(Fmt.hours(sleep.asleepHours)) (score \(sleep.score)).")
        if let e = b.energy { parts.append("Energy \(e.current).") }
        if let t = b.strain?.targetLow, let h = b.strain?.targetHigh { parts.append("Strain target \(t)–\(h).") }
        send(id: "checkin-morning-\(b.day)", title: "Morning summary", body: parts.joined(separator: " "))
    }

    private func scheduleJournalReminder(enabled: Bool, minutes: Int, journaledToday: Bool, now: Date, calendar: Calendar) {
        center.removePendingNotificationRequests(withIdentifiers: [ID.journal])
        guard enabled else { return }
        let todayAt = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(minutes * 60))
        // Skip today if it is already journaled or the time has passed; remind tomorrow instead.
        let fire = (journaledToday || todayAt <= now) ? calendar.date(byAdding: .day, value: 1, to: todayAt)! : todayAt
        schedule(id: ID.journal, title: "Journal", body: "Log today's habits so Insights can test them against your HRV.",
                 at: fire, calendar: calendar)
    }

    /// Fifteen minutes before today's caffeine cut-off, on days with caffeine logged.
    private func scheduleCaffeineCutoff(_ b: DailyBrief, enabled: Bool, now: Date) {
        center.removePendingNotificationRequests(withIdentifiers: [ID.caffeine])
        guard enabled, let i = b.intake, i.caffeineTodayMg > 0, let cut = i.cutoff else { return }
        let fire = cut.addingTimeInterval(-15 * 60)
        guard fire > now else { return }
        let clock = cut.formatted(date: .omitted, time: .shortened)
        schedule(id: ID.caffeine, title: "Caffeine cut-off at \(clock)",
                 body: String(format: "After that, one more coffee leaves over %.0f mg in your body at bedtime.", i.limitMg),
                 at: fire, calendar: .current)
    }

    /// Sunday from 18:00, once per week.
    private func weeklyReview(_ b: DailyBrief, enabled: Bool, now: Date, calendar: Calendar, prefs: Preferences) {
        guard enabled, calendar.component(.weekday, from: now) == 1, calendar.component(.hour, from: now) >= 18,
              prefs.lastWeeklyReviewDay != b.day.description else { return }
        prefs.lastWeeklyReviewDay = b.day.description
        let week = b.history.suffix(7)
        let scores = week.compactMap(\.recoveryScore)
        let loads = week.compactMap(\.load)
        var parts: [String] = []
        if !scores.isEmpty {
            parts.append("Recovery averaged \(scores.reduce(0, +) / scores.count) over \(scores.count) scored day(s).")
        }
        if !loads.isEmpty { parts.append(String(format: "Total load %.0f.", loads.reduce(0, +))) }
        if let debt = b.sleep?.debtHours { parts.append("Sleep debt \(Fmt.hours(debt)).") }
        if parts.isEmpty { parts.append("Not enough data this week yet.") }
        send(id: "checkin-weekly-\(b.day)", title: "Weekly review", body: parts.joined(separator: " "))
    }

    private func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            Task { @MainActor in
                AppModel.shared.log(.notification, error == nil ? .info : .error,
                                    error.map { "\(title) failed: \($0.localizedDescription)" } ?? "\(title) sent")
            }
        }
    }

    private func schedule(id: String, title: String, body: String, at date: Date, calendar: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        center.add(request) { error in
            if let error {
                Task { @MainActor in AppModel.shared.log(.notification, .error, "\(title) schedule failed: \(error.localizedDescription)") }
            }
        }
    }
}
