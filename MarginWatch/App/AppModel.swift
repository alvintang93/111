import Foundation
import MarginCore
import UserNotifications
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// 60-day baselines + 60 days of score calibration.
    static let historyDays = 120

    static let defaultTags = [
        "Alcohol", "Late meal", "Late caffeine", "High stress",
        "Travel", "Sauna", "Illness symptoms", "Screens in bed",
    ]

    @Published private(set) var brief: DailyBrief?
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress: Double?
    @Published private(set) var status: String?
    @Published private(set) var journal: [Day: Set<String>]
    @Published var settings: UserSettings {
        didSet {
            guard settings != oldValue else { return }
            prefs.saveSettings(settings)
            rescore()
        }
    }

    private let health = HealthService()
    private let recordStore = RecordStore()
    private let prefs = Preferences()
    private var records: [Day: DayRecord]

    private var calendar: Calendar { .current }
    var today: Day { Day(Date(), calendar: calendar) }

    private init() {
        settings = prefs.loadSettings()
        journal = prefs.loadJournal()
        records = recordStore.load()
        brief = SharedStore.loadBrief()
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        guard HealthService.isAvailable else {
            status = "Health data is not available on this device."
            return
        }
        if !prefs.hasRequestedAuthorization {
            do {
                try await health.requestAuthorization()
                prefs.hasRequestedAuthorization = true
            } catch {
                status = "Health authorization failed: \(error.localizedDescription)"
            }
            var s = settings
            if s.age == nil { s.age = health.age() }
            if s.sex == .unspecified, let sex = health.sex() { s.sex = sex }
            settings = s
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        await refresh()
    }

    /// Re-reads HealthKit for days not yet cached plus today and yesterday,
    /// then rescores. On failure the last good brief stays on screen.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            progress = nil
        }
        let cal = calendar
        let today = self.today
        let days = Day.range(from: today.adding(-(Self.historyDays - 1), calendar: cal), to: today, calendar: cal)
        let alwaysRefresh: Set<Day> = [today, today.adding(-1, calendar: cal)]
        let needed = days.filter { records[$0] == nil || alwaysRefresh.contains($0) }

        do {
            if let first = needed.first, let last = needed.last {
                let span = DateInterval(start: RawDayInput.fetchInterval(for: first, calendar: cal).start,
                                        end: RawDayInput.fetchInterval(for: last, calendar: cal).end)
                let sleep = try await health.sleep(in: span)
                let hrv = try await health.hrv(in: span)
                let rhr = try await health.restingHR(in: span)
                let rr = try await health.respiratoryRate(in: span)
                let temp = try await health.wristTemperature(in: span)
                if needed.count > 2 { progress = 0 }
                for (k, day) in needed.enumerated() {
                    let hr = try await health.heartRate(in: RawDayInput.fetchInterval(for: day, calendar: cal))
                    let input = RawDayInput(sleep: sleep, hrv: hrv, heartRate: hr, restingHR: rhr,
                                            respiratoryRate: rr, wristTemperature: temp)
                    records[day] = await Task.detached(priority: .userInitiated) {
                        DayRecordBuilder.build(day: day, calendar: cal, input: input)
                    }.value
                    if progress != nil { progress = Double(k + 1) / Double(needed.count) }
                }
                recordStore.save(records)
            }
            status = nil
        } catch {
            status = "Couldn't read Health data (\(error.localizedDescription)). Showing last saved results."
        }
        rescore()
    }

    /// Drops the cache and rebuilds every day from HealthKit.
    func rebuildHistory() async {
        recordStore.clear()
        records = [:]
        await refresh()
    }

    // MARK: - Scoring

    func rescore() {
        let engine = Engine(records: Array(records.values), today: today, settings: settings, calendar: calendar)
        let b = engine.brief(journal: journal)
        brief = b
        SharedStore.saveBrief(b)
        WidgetCenter.shared.reloadAllTimelines()
        notifyIfNeeded(b)
    }

    private func notifyIfNeeded(_ b: DailyBrief) {
        guard b.recovery.flags.contains(.illnessWatch),
              prefs.lastIllnessAlertDay != b.day.description else { return }
        prefs.lastIllnessAlertDay = b.day.description
        let content = UNMutableNotificationContent()
        content.title = "Illness watch"
        content.body = "Sleeping heart rate and temperature/respiration are both well above your baseline. Consider a rest day."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "illness-\(b.day)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Journal

    func tags(on day: Day) -> Set<String>? { journal[day] }

    func setTag(_ tag: String, on day: Day, enabled: Bool) {
        var set = journal[day] ?? []
        if enabled { set.insert(tag) } else { set.remove(tag) }
        journal[day] = set
        prefs.saveJournal(journal)
        rescore()
    }

    /// Records the day as journaled with whatever tags are set (possibly none).
    func confirmJournal(_ day: Day) {
        if journal[day] == nil { journal[day] = [] }
        prefs.saveJournal(journal)
        rescore()
    }

    func clearJournal(_ day: Day) {
        journal[day] = nil
        prefs.saveJournal(journal)
        rescore()
    }
}
