import Foundation

public enum MarginCoreInfo {
    /// Bumped whenever scoring rules change, so logs can be compared across versions.
    public static let engineVersion = "2.3.0"
}

// MARK: - Complication state

/// Everything a complication renders, derived purely from the persisted brief.
/// Keeping this logic here (not in the widget) makes every state testable.
public struct ComplicationState: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A score is shown (possibly degraded or provisional).
        case score
        /// No score yet: building the HRV baseline.
        case calibrating
        /// No score: overnight window still open.
        case pending
        /// No score: inputs missing (no overnight data, HRV unavailable).
        case unavailable
        /// The saved brief is from a previous day; never shown as today's.
        case stale
        /// Nothing saved yet.
        case noBrief
    }

    public var kind: Kind
    public var scoreText: String
    /// 0...1 for gauges; 0 when there is no score.
    public var gaugeFraction: Double
    public var band: RecoveryBand
    public var directive: Directive?
    /// Short label, e.g. "REC 62", "CALIBRATING 9/14", "NO SCORE".
    public var headline: String
    /// Second line, e.g. "Load 40 / 46-77" or a short reason.
    public var detail: String
    /// Third line: qualifier, flag or sync time.
    public var footnote: String
    /// True when the footnote is a warning (degraded, provisional, old sync).
    public var footnoteIsWarning: Bool
    /// One line for inline complications.
    public var inline: String

    public static func make(brief: DailyBrief?, now: Date, calendar: Calendar,
                            syncStaleAfter: TimeInterval = 12 * 3600) -> ComplicationState {
        guard let b = brief else {
            return ComplicationState(kind: .noBrief, scoreText: "–", gaugeFraction: 0, band: .unknown, directive: nil,
                                     headline: "Margin", detail: "Open the app to start", footnote: "",
                                     footnoteIsWarning: false, inline: "Margin · open app")
        }
        guard b.day == Day(now, calendar: calendar) else {
            return ComplicationState(kind: .stale, scoreText: "–", gaugeFraction: 0, band: .unknown, directive: nil,
                                     headline: "Margin", detail: "Open to update",
                                     footnote: "Last result: \(b.day)", footnoteIsWarning: true,
                                     inline: "Margin · open to update")
        }
        let r = b.recovery
        switch r.status {
        case .nightInProgress:
            return ComplicationState(kind: .pending, scoreText: "…", gaugeFraction: 0, band: .unknown,
                                     directive: .pending, headline: "PENDING", detail: "Ready after you wake",
                                     footnote: syncLine(b, now: now, calendar: calendar, staleAfter: syncStaleAfter).0,
                                     footnoteIsWarning: false, inline: "Margin · pending")
        case .calibrating:
            let c = r.calibration
            let fraction = c.hrvNightsRequired > 0 ? min(Double(c.hrvNights) / Double(c.hrvNightsRequired), 1) : 0
            return ComplicationState(kind: .calibrating, scoreText: "\(c.hrvNights)/\(c.hrvNightsRequired)",
                                     gaugeFraction: fraction, band: .unknown, directive: .calibrating,
                                     headline: "CALIBRATING \(c.hrvNights)/\(c.hrvNightsRequired)",
                                     detail: "HRV nights collected", footnote: "No score yet",
                                     footnoteIsWarning: false, inline: "Calibrating \(c.hrvNights)/\(c.hrvNightsRequired)")
        case .hrvUnavailable, .noOvernightData:
            let reason = r.status == .hrvUnavailable ? "HRV unavailable" : "No overnight data"
            return ComplicationState(kind: .unavailable, scoreText: "–", gaugeFraction: 0, band: .unknown,
                                     directive: .noData, headline: "NO SCORE", detail: reason,
                                     footnote: "Open app for details", footnoteIsWarning: true,
                                     inline: "No score · \(reason.lowercased())")
        case .degraded, .provisional, .scored:
            guard let s = r.score else {
                return make(brief: nil, now: now, calendar: calendar, syncStaleAfter: syncStaleAfter)
            }
            let d = b.plan.directive
            var detail = "Load \(fmt(b.load.todayLoad))"
            if let lo = b.plan.targetLow, let hi = b.plan.targetHigh {
                detail += " / \(fmt(lo))-\(fmt(hi))"
            }
            var footnote: String
            var warning = false
            if r.status == .degraded {
                footnote = "Partial data"
                warning = true
            } else if r.status == .provisional {
                footnote = "Scale calibrating"
                warning = true
            } else if let f = r.flags.first {
                footnote = flagLabel(f)
                warning = true
            } else {
                let (line, old) = syncLine(b, now: now, calendar: calendar, staleAfter: syncStaleAfter)
                footnote = line
                warning = old
            }
            return ComplicationState(kind: .score, scoreText: "\(s)", gaugeFraction: Double(s) / 100, band: r.band,
                                     directive: d, headline: "REC \(s)", detail: detail, footnote: footnote,
                                     footnoteIsWarning: warning, inline: "\(s) · \(directiveTitle(d))")
        }
    }

    public static func directiveTitle(_ d: Directive) -> String {
        switch d {
        case .push: return "PUSH"
        case .maintain: return "MAINTAIN"
        case .recover: return "RECOVER"
        case .rest: return "REST"
        case .calibrating: return "CALIBRATING"
        case .noData: return "NO DATA"
        case .pending: return "PENDING"
        }
    }

    public static func flagLabel(_ f: Flag) -> String {
        switch f {
        case .elevatedVitals: return "Vitals above usual"
        case .hrvTrendLow: return "HRV trend low"
        case .loadSpike: return "Load spike"
        case .sleepDebt: return "Sleep debt"
        }
    }

    static func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "–" }

    /// "Synced 07:42" from the brief's data sync time; flags syncs older than `staleAfter`.
    static func syncLine(_ b: DailyBrief, now: Date, calendar: Calendar, staleAfter: TimeInterval) -> (String, Bool) {
        guard let t = b.dataSyncedAt else { return ("Not synced", true) }
        let c = calendar.dateComponents([.hour, .minute], from: t)
        let line = String(format: "Synced %02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return (line, now.timeIntervalSince(t) > staleAfter)
    }
}

// MARK: - Event log

/// Structured pipeline event. Messages carry counts, dates and decisions,
/// never raw health values.
public struct PipelineEvent: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case auth, query, plan, build, score, persist, widget, background, notification, lifecycle
    }

    public enum Level: String, Codable, Sendable {
        case info, warning, error
    }

    public var at: Date
    public var stage: Stage
    public var level: Level
    public var message: String

    public init(at: Date, stage: Stage, level: Level, message: String) {
        self.at = at
        self.stage = stage
        self.level = level
        self.message = message
    }
}

/// Fixed-capacity ring of recent events, persisted on device for the diagnostics screen.
public struct EventLog: Codable, Sendable, Equatable {
    public private(set) var events: [PipelineEvent]
    public let capacity: Int

    public init(capacity: Int = 300) {
        self.capacity = max(1, capacity)
        self.events = []
    }

    public mutating func append(_ e: PipelineEvent) {
        events.append(e)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    public func latest(_ stage: PipelineEvent.Stage) -> PipelineEvent? {
        events.last { $0.stage == stage }
    }

    public func latestError() -> PipelineEvent? {
        events.last { $0.level == .error }
    }
}

// MARK: - Decision log (as issued)

public struct ComponentZ: Codable, Sendable, Equatable {
    public var kind: ComponentKind
    public var z: Double
}

public struct DecisionLogEntry: Codable, Sendable, Equatable, Identifiable {
    public var day: Day
    public var issuedAt: Date
    public var engineVersion: String
    public var status: ScoreStatus
    public var directive: Directive
    public var score: Int?
    public var relativeZ: Double?
    public var components: [ComponentZ]
    public var flags: [Flag]
    public var id: String { day.description }
}

/// The final recommendation actually shown for each day (last update wins).
/// Lets threshold behaviour on real data be reviewed later without
/// retaining raw health values. Never changes a threshold.
public struct DecisionLog: Codable, Sendable, Equatable {
    public private(set) var entries: [DecisionLogEntry]
    public let retentionDays: Int

    public init(retentionDays: Int = 180) {
        self.retentionDays = max(1, retentionDays)
        self.entries = []
    }

    public mutating func record(_ brief: DailyBrief, at time: Date) {
        let entry = DecisionLogEntry(
            day: brief.day, issuedAt: time, engineVersion: MarginCoreInfo.engineVersion,
            status: brief.recovery.status, directive: brief.plan.directive, score: brief.recovery.score,
            relativeZ: brief.recovery.relativeZ,
            components: brief.recovery.components.map { ComponentZ(kind: $0.kind, z: $0.z) },
            flags: brief.recovery.flags)
        entries.removeAll { $0.day == brief.day }
        entries.append(entry)
        entries.sort { $0.day < $1.day }
        if entries.count > retentionDays { entries.removeFirst(entries.count - retentionDays) }
    }

    public func directiveCounts() -> [CountEntry] {
        Directive.allCases.map { d in CountEntry(key: d.rawValue, count: entries.filter { $0.directive == d }.count) }
    }
}

// MARK: - Persisted cache file

public struct RecordCacheFile: Codable, Sendable, Equatable {
    public var schema: Int
    public var savedAt: Date
    public var records: [DayRecord]

    public enum DecodeResult: Equatable {
        case ok([DayRecord], savedAt: Date)
        /// Older/newer schema: the cache is discarded and rebuilt from HealthKit.
        case schemaMismatch(found: Int, expected: Int)
        case corrupt(String)
    }

    public init(records: [Day: DayRecord], savedAt: Date, retentionDays: Int) {
        schema = DayRecord.schemaVersion
        self.savedAt = savedAt
        self.records = Array(records.values.sorted { $0.day < $1.day }.suffix(retentionDays))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) -> DecodeResult {
        struct Header: Decodable { var schema: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return .corrupt("unreadable header")
        }
        guard header.schema == DayRecord.schemaVersion else {
            return .schemaMismatch(found: header.schema, expected: DayRecord.schemaVersion)
        }
        do {
            let file = try JSONDecoder().decode(RecordCacheFile.self, from: data)
            return .ok(file.records, savedAt: file.savedAt)
        } catch {
            return .corrupt(String(String(describing: error).prefix(200)))
        }
    }
}

// MARK: - Runtime status (app and widget heartbeats)

/// Written only by the app. Shared with the complication via the App Group.
public struct AppRuntimeStatus: Codable, Sendable, Equatable {
    public var lastForegroundSync: Date?
    public var lastBackgroundTaskRun: Date?
    /// Most recent background-task executions (not requests), newest last.
    public var backgroundRuns: [Date] = []
    public var lastBackgroundRequestAt: Date?
    public var lastBackgroundPreferredDate: Date?
    public var lastBackgroundScheduleError: String?
    public var lastSuccessfulSync: Date?
    public var lastSyncMode: SyncMode?
    public var lastSyncDaysBuilt: Int?
    public var lastSyncError: String?
    public var lastSyncErrorAt: Date?
    public var lastPersistError: String?
    public var authorizationRequestStatus: String?
    public var authorizationRequestedAt: Date?
    public var lastBriefAt: Date?
    public var lastWidgetReloadRequestAt: Date?

    public init() {}

    public mutating func recordBackgroundRun(_ t: Date, keep: Int = 20) {
        lastBackgroundTaskRun = t
        backgroundRuns.append(t)
        if backgroundRuns.count > keep { backgroundRuns.removeFirst(backgroundRuns.count - keep) }
    }
}

/// Written only by the complication extension each time WidgetKit asks for a timeline.
public struct WidgetHeartbeat: Codable, Sendable, Equatable {
    public var lastTimelineAt: Date?
    public var nextRefreshRequested: Date?
    public var lastKind: ComplicationState.Kind?
    public var briefDecoded: Bool = false
    public var timelines: Int = 0

    public init() {}
}
