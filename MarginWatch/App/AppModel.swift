import Foundation
import HealthKit
import MarginCore
import os
import UserNotifications
import WidgetKit

enum SyncFailure: Error, CustomStringConvertible {
    case query(input: String, underlying: Error)

    var description: String {
        switch self {
        case .query(let input, let e):
            if let hk = e as? HKError, hk.code == .errorDatabaseInaccessible {
                return "\(input) query: Health database locked (watch locked)"
            }
            return "\(input) query: \(e.localizedDescription)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    static let defaultTags = [
        "Alcohol", "Late meal", "Late caffeine", "High stress",
        "Travel", "Sauna", "Feeling unwell", "Screens in bed",
    ]

    @Published private(set) var brief: DailyBrief?
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress: Double?
    @Published private(set) var status: String?
    @Published private(set) var journal: [Day: Set<String>]
    @Published private(set) var runtime: AppRuntimeStatus
    @Published private(set) var events: [PipelineEvent]
    @Published private(set) var decisionLog: DecisionLog
    @Published private(set) var widgetHeartbeat: WidgetHeartbeat?
    @Published private(set) var authorizationResolved = false
    @Published var settings: UserSettings {
        didSet {
            guard settings != oldValue else { return }
            prefs.saveSettings(settings)
            log(.lifecycle, .info, "settings changed; rescoring")
            rescore()
        }
    }

    let syncParams = SyncParameters.standard

    private let health = HealthService()
    private let recordStore = RecordStore()
    private let prefs = Preferences()
    private let eventStore = JSONFileStore<EventLog>(fileName: "event-log.json")
    private let decisionStore = JSONFileStore<DecisionLog>(fileName: "decision-log.json")
    private var eventLog: EventLog
    private(set) var records: [Day: DayRecord]
    private let osLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Margin", category: "pipeline")

    private var calendar: Calendar { .current }
    var today: Day { Day(Date(), calendar: calendar) }

    private init() {
        settings = prefs.loadSettings()
        journal = prefs.loadJournal()
        runtime = prefs.loadRuntime()
        let loadedLog = eventStore.load() ?? EventLog(capacity: 300)
        eventLog = loadedLog
        events = loadedLog.events
        decisionLog = decisionStore.load() ?? DecisionLog(retentionDays: 180)
        widgetHeartbeat = SharedStore.loadHeartbeat()
        let (loaded, outcome) = recordStore.load()
        records = loaded
        switch outcome {
        case .loaded(let count, let savedAt):
            log(.persist, .info, "cache loaded: \(count) day(s), saved \(savedAt.formatted(date: .abbreviated, time: .shortened))")
        case .empty:
            log(.persist, .info, "no cache on disk (first launch or cleared)")
        case .discarded(let reason):
            log(.persist, .warning, "cache discarded: \(reason)")
        }
        switch SharedStore.loadBriefResult() {
        case .loaded(let b): brief = b
        case .none: brief = nil
        case .undecodable(let why):
            brief = nil
            log(.persist, .warning, "saved brief unreadable (\(why)); will recompute")
        }
        if !SharedStore.groupAvailable {
            log(.widget, .error, "App Group container unavailable: complications cannot read results. Check APP_GROUP_ID and entitlements.")
        }
    }

    /// Last 7 records, newest first (diagnostics).
    var recentRecords: [DayRecord] {
        records.values.sorted { $0.day > $1.day }.prefix(7).map { $0 }
    }

    // MARK: - Logging

    func log(_ stage: PipelineEvent.Stage, _ level: PipelineEvent.Level, _ message: String) {
        let e = PipelineEvent(at: Date(), stage: stage, level: level, message: message)
        eventLog.append(e)
        events = eventLog.events
        switch level {
        case .info: osLog.info("[\(stage.rawValue, privacy: .public)] \(message, privacy: .public)")
        case .warning: osLog.warning("[\(stage.rawValue, privacy: .public)] \(message, privacy: .public)")
        case .error: osLog.error("[\(stage.rawValue, privacy: .public)] \(message, privacy: .public)")
        }
    }

    private func flushLogs() {
        do {
            try eventStore.save(eventLog)
        } catch {
            osLog.error("event log save failed: \(String(describing: error), privacy: .public)")
            runtime.lastPersistError = "event log: \(error)"
        }
        prefs.saveRuntime(runtime)
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        log(.lifecycle, .info, "app launched (engine \(MarginCoreInfo.engineVersion))")
        guard HealthService.isAvailable else {
            status = "Health data is not available on this device."
            log(.auth, .error, "HealthKit not available on this device")
            flushLogs()
            return
        }
        await ensureAuthorization(interactive: true)
        await sync(mode: .foreground)
    }

    /// Foreground re-entry. If authorization is still unresolved (e.g. the
    /// status query failed earlier) it is re-checked; the in-flight guard keeps
    /// this from racing the launch path's permission prompt.
    func onBecameActive() async {
        if !authorizationResolved {
            await ensureAuthorization(interactive: true)
        }
        guard authorizationResolved else { return }
        await sync(mode: .foreground)
    }

    private var authorizationInFlight = false

    func ensureAuthorization(interactive: Bool) async {
        guard !authorizationInFlight else { return }
        authorizationInFlight = true
        defer { authorizationInFlight = false }
        var requestStatus = await health.requestStatus()
        log(.auth, .info, "authorization request status: \(requestStatus.label)")
        if requestStatus == .shouldRequest && interactive {
            do {
                try await health.requestAuthorization()
                runtime.authorizationRequestedAt = Date()
                requestStatus = await health.requestStatus()
                log(.auth, .info, "permission sheet answered; status now \(requestStatus.label). Read grants are not visible to apps; see per-input data counts.")
                var s = settings
                if s.age == nil { s.age = health.age() }
                if s.sex == .unspecified, let sex = health.sex() { s.sex = sex }
                if s != settings { settings = s }
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                log(.notification, .info, "notification permission \(granted ? "granted" : "not granted")")
            } catch {
                log(.auth, .error, "authorization request failed: \(error.localizedDescription)")
            }
        }
        runtime.authorizationRequestStatus = requestStatus.label
        authorizationResolved = requestStatus == .unnecessary
        if !authorizationResolved {
            log(.auth, .warning, "authorization not resolved (\(requestStatus.label)); syncing is paused")
        }
        prefs.saveRuntime(runtime)
    }

    func backgroundRefresh() async {
        runtime.recordBackgroundRun(Date())
        log(.background, .info, "background refresh task executed")
        if !authorizationResolved {
            // Cannot prompt in the background; only check.
            authorizationResolved = await health.requestStatus() == .unnecessary
        }
        await sync(mode: .background)
    }

    func recordBackgroundRequest(preferred: Date, error: Error?) {
        runtime.lastBackgroundRequestAt = Date()
        runtime.lastBackgroundPreferredDate = preferred
        runtime.lastBackgroundScheduleError = error.map { String(describing: $0) }
        if let error {
            log(.background, .error, "background refresh request failed: \(error.localizedDescription)")
        } else {
            log(.background, .info, "background refresh requested for \(preferred.formatted(date: .omitted, time: .shortened)) (watchOS decides when it runs)")
        }
        prefs.saveRuntime(runtime)
    }

    // MARK: - Sync

    func sync(mode: SyncMode) async {
        guard !isRefreshing else {
            log(.lifecycle, .info, "\(mode.rawValue) sync skipped: another sync is running")
            return
        }
        guard authorizationResolved else {
            status = "Waiting for Health permission. Open Margin to grant access."
            log(.auth, .warning, "\(mode.rawValue) sync skipped: Health authorization not resolved")
            rescore()
            flushLogs()
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            progress = nil
        }
        let started = Date()
        let cal = calendar
        let today = Day(started, calendar: cal)
        do {
            var small = RawDayInput()
            var fingerprints: [Day: String]?
            if mode == .foreground {
                let from = today.adding(-(syncParams.historyDays + 1), calendar: cal).date(calendar: cal)
                let to = today.adding(2, calendar: cal).date(calendar: cal)
                small = try await fetchSmallInputs(DateInterval(start: from, end: to))
                let historyStart = today.adding(-(syncParams.historyDays - 1), calendar: cal)
                let inWindow = records.filter { $0.key >= historyStart }
                let input = small
                fingerprints = await Task.detached(priority: .userInitiated) {
                    SyncPlanner.fingerprints(for: inWindow, input: input, asOf: started, calendar: cal)
                }.value
            }
            let plan = SyncPlanner.plan(existing: records, today: today, calendar: cal, now: started, mode: mode,
                                        currentFingerprints: fingerprints, params: syncParams)
            let counts = SyncPlan.Reason.allCases.map { "\($0.rawValue) \(plan.count($0))" }.joined(separator: ", ")
            log(.plan, .info, "\(mode.rawValue) plan: \(plan.items.count) day(s) [\(counts)], deferred \(plan.deferred.count)")

            if mode == .background, let start = plan.items.map(\.windows.union.start).min(),
               let end = plan.items.map(\.windows.union.end).max() {
                small = try await fetchSmallInputs(DateInterval(start: start, end: end))
            }

            if plan.items.count > 3 { progress = 0 }
            var sinceSave = 0
            var backfilled = 0, backfilledEmpty = 0
            for (k, item) in plan.items.enumerated() {
                let hr: [HRSample]
                do {
                    hr = try await health.heartRate(in: item.windows.union)
                } catch {
                    throw SyncFailure.query(input: "heart rate (\(item.day))", underlying: error)
                }
                var dayInput = small
                dayInput.heartRate = hr
                let input = dayInput
                let record = await Task.detached(priority: .userInitiated) {
                    DayRecordBuilder.build(day: item.day, windows: item.windows, input: input,
                                           asOf: started, builtAt: started)
                }.value
                let previous = records[item.day]
                records[item.day] = record
                if item.reason == .missing {
                    backfilled += 1
                    if record.isEmpty { backfilledEmpty += 1 }
                } else {
                    logBuild(item: item, record: record, previous: previous)
                }
                sinceSave += 1
                if sinceSave >= syncParams.saveEvery {
                    persistRecords(at: Date())
                    sinceSave = 0
                }
                if progress != nil { progress = Double(k + 1) / Double(plan.items.count) }
            }
            if backfilled > 0 {
                log(.build, .info, "built \(backfilled) new day(s), \(backfilledEmpty) with no Health data")
            }
            persistRecords(at: Date())
            runtime.lastSuccessfulSync = Date()
            runtime.lastSyncMode = mode
            runtime.lastSyncDaysBuilt = plan.items.count
            runtime.lastSyncError = nil
            if mode == .foreground { runtime.lastForegroundSync = Date() }
            status = nil
            log(.query, .info, String(format: "\(mode.rawValue) sync complete: %ld day(s) in %.1f s", plan.items.count,
                                      Date().timeIntervalSince(started)))
        } catch {
            let message = (error as? SyncFailure)?.description ?? error.localizedDescription
            runtime.lastSyncError = message
            runtime.lastSyncErrorAt = Date()
            status = "Couldn't read Health data. Showing the last saved results."
            log(.query, .error, "\(mode.rawValue) sync aborted, previous data kept: \(message)")
            persistRecords(at: Date())
        }
        rescore()
        flushLogs()
    }

    /// Non-heart-rate inputs over `interval`. Any failure aborts the sync: a
    /// failed query must never be mistaken for "no data", which would look like
    /// a deletion and trigger rebuilds that drop real data.
    private func fetchSmallInputs(_ interval: DateInterval) async throws -> RawDayInput {
        func step<T>(_ name: String, _ op: () async throws -> T) async throws -> T {
            do { return try await op() } catch { throw SyncFailure.query(input: name, underlying: error) }
        }
        let sleep = try await step("sleep") { try await health.sleep(in: interval) }
        let hrv = try await step("HRV") { try await health.hrv(in: interval) }
        let rhr = try await step("resting HR") { try await health.restingHR(in: interval) }
        let rr = try await step("respiratory rate") { try await health.respiratoryRate(in: interval) }
        let temp = try await step("wrist temperature") { try await health.wristTemperature(in: interval) }
        let workouts = try await step("workouts") { try await health.workouts(in: interval) }
        let days = Int((interval.duration / 86400).rounded())
        log(.query, .info, "queried \(days) day(s): sleep \(sleep.segments.count), HRV \(hrv.count), resting HR \(rhr.count), resp \(rr.count), temp \(temp.count), workouts \(workouts.count)")
        if sleep.unknownValues > 0 {
            log(.query, .warning, "\(sleep.unknownValues) sleep sample(s) with an unrecognised value skipped")
        }
        return RawDayInput(sleep: sleep.segments, hrv: hrv, heartRate: [], restingHR: rhr,
                           respiratoryRate: rr, wristTemperature: temp, workouts: workouts)
    }

    private func logBuild(item: SyncPlan.Item, record: DayRecord, previous: DayRecord?) {
        var head = "day \(item.day) [\(item.reason.rawValue)]"
        if let p = previous {
            head += p.sourceFingerprint == record.sourceFingerprint ? " replaced (source unchanged)" : " replaced (source data changed)"
            if (p.lnHRV == nil) != (record.lnHRV == nil) {
                head += record.lnHRV == nil ? "; HRV now missing" : "; HRV now present"
            }
        }
        let level: PipelineEvent.Level = item.reason == .sourceChanged ? .warning : .info
        log(.build, level, head + ": " + DayQuality.notes(for: record).joined(separator: "; "))
    }

    private func persistRecords(at time: Date) {
        do {
            try recordStore.save(records, at: time)
            runtime.lastPersistError = nil
        } catch {
            runtime.lastPersistError = "records: \(error)"
            log(.persist, .error, "record cache save failed: \(error)")
        }
    }

    /// Drops the cache and rebuilds every day from HealthKit.
    func rebuildHistory() async {
        do {
            try recordStore.clear()
            log(.persist, .warning, "cache cleared by user; full rebuild")
        } catch {
            log(.persist, .error, "cache clear failed: \(error.localizedDescription)")
        }
        records = [:]
        await sync(mode: .foreground)
    }

    // MARK: - Scoring

    func rescore() {
        let now = Date()
        let engine = Engine(records: Array(records.values), today: Day(now, calendar: calendar), settings: settings,
                            calendar: calendar, asOf: now)
        let b = engine.brief(journal: journal, generatedAt: now, dataSyncedAt: runtime.lastSuccessfulSync)
        brief = b
        if let error = SharedStore.saveBrief(b) {
            runtime.lastPersistError = "brief: \(error)"
            log(.persist, .error, "brief save for complications failed: \(error)")
        }
        decisionLog.record(b, at: now)
        do {
            try decisionStore.save(decisionLog)
        } catch {
            log(.persist, .error, "decision log save failed: \(error)")
        }
        WidgetCenter.shared.reloadAllTimelines()
        runtime.lastBriefAt = now
        runtime.lastWidgetReloadRequestAt = now
        let r = b.recovery
        log(.score, r.status.hasScore ? .info : .warning,
            "brief \(b.day): status \(r.status.rawValue), directive \(b.plan.directive.rawValue), "
                + "score \(r.score.map { "\($0)" } ?? "withheld"), HRV nights \(r.calibration.hrvNights)/\(r.calibration.hrvNightsRequired), "
                + "scale days \(r.calibration.compositeDays)/\(r.calibration.compositeDaysRequired)")
        widgetHeartbeat = SharedStore.loadHeartbeat()
        notifyIfNeeded(b)
    }

    func refreshHeartbeat() {
        widgetHeartbeat = SharedStore.loadHeartbeat()
    }

    private func notifyIfNeeded(_ b: DailyBrief) {
        guard b.recovery.flags.contains(.elevatedVitals),
              prefs.lastVitalsAlertDay != b.day.description else { return }
        prefs.lastVitalsAlertDay = b.day.description
        let content = UNMutableNotificationContent()
        content.title = "Overnight readings above usual"
        content.body = "Sleeping heart rate and temperature or respiration were well above your usual range. Consider an easier day."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "vitals-\(b.day)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { @MainActor in AppModel.shared.log(.notification, .error, "notification failed: \(error.localizedDescription)") }
            }
        }
        log(.notification, .info, "elevated-vitals notification requested for \(b.day)")
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
