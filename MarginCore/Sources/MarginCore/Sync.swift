import Foundation

public enum SyncMode: String, Codable, Sendable {
    /// App on screen: full reconciliation of the history window.
    case foreground
    /// watchOS background refresh: short time budget, recent days only.
    case background
}

public struct SyncParameters: Sendable, Equatable {
    /// 60-day baselines + 60 days of score calibration.
    public var historyDays = 120
    /// Today and the previous days rebuilt on every sync (late-arriving data).
    public var reconcileDays = 3
    /// Upper bound on days built in one background task.
    public var backgroundMaxBuilds = 2
    /// Empty days are re-queried at most this often (permission granted later,
    /// data synced late from another source).
    public var emptyRetryInterval: TimeInterval = 24 * 3600
    /// Persist the cache after this many newly built days during a backfill.
    public var saveEvery = 10

    public init() {}

    public static let standard = SyncParameters()
}

public struct SyncPlan: Sendable, Equatable {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// Never built.
        case missing
        /// Within the reconciliation window (data may still arrive).
        case recent
        /// Non-heart-rate HealthKit data for the day changed since it was built
        /// (added, corrected, deleted or hidden by a permission change).
        case sourceChanged
        /// Built empty; retried in case data or permission arrived later.
        case retryEmpty
    }

    public struct Item: Sendable, Equatable {
        public var day: Day
        public var windows: DayWindows
        public var reason: Reason
        /// True when an existing record will be replaced.
        public var replaces: Bool
    }

    public var items: [Item]
    public var historyStart: Day
    /// Days skipped because the background budget was exhausted.
    public var deferred: [Day]

    public func count(_ reason: Reason) -> Int { items.filter { $0.reason == reason }.count }
}

public enum SyncPlanner {
    /// Decides which days to (re)build and with which windows. Pure: the app
    /// executes the plan; tests drive it directly.
    ///
    /// - Parameter currentFingerprints: fingerprints of the latest non-heart-rate
    ///   HealthKit data for existing records (foreground only). Nil skips
    ///   change detection.
    public static func plan(existing: [Day: DayRecord], today: Day, calendar: Calendar, now: Date,
                            mode: SyncMode, currentFingerprints: [Day: String]?,
                            params: SyncParameters = .standard) -> SyncPlan {
        let start = today.adding(-(params.historyDays - 1), calendar: calendar)
        let days = Day.range(from: start, to: today, calendar: calendar)
        let recentFrom = today.adding(-(params.reconcileDays - 1), calendar: calendar)

        var candidates: [SyncPlan.Item] = []
        var previousWindows: DayWindows? = existing[start.adding(-1, calendar: calendar)]?.windows
        for day in days {
            let record = existing[day]
            let reason: SyncPlan.Reason?
            if record == nil {
                reason = .missing
            } else if day >= recentFrom {
                reason = .recent
            } else if let fp = currentFingerprints?[day], fp != record?.sourceFingerprint {
                reason = .sourceChanged
            } else if let r = record, r.isEmpty,
                      now.timeIntervalSince(r.builtAt ?? .distantPast) >= params.emptyRetryInterval {
                reason = .retryEmpty
            } else {
                reason = nil
            }
            // Existing records keep their windows; new days chain from the previous day.
            let windows = record?.windows ?? DayWindows.chained(for: day, calendar: calendar, previous: previousWindows)
            if let reason {
                candidates.append(SyncPlan.Item(day: day, windows: windows, reason: reason, replaces: record != nil))
            }
            previousWindows = windows
        }

        // New days must also end where an existing next day begins (a backfilled
        // day before a record built in another time zone would otherwise overlap it).
        for k in candidates.indices where !candidates[k].replaces {
            guard let next = existing[candidates[k].day.adding(1, calendar: calendar)]?.windows else { continue }
            var w = candidates[k].windows
            if next.activity.start > w.activity.start && next.activity.start < w.activity.end {
                w.activity = DateInterval(start: w.activity.start, end: next.activity.start)
            }
            if next.night.start > w.night.start && next.night.start < w.night.end {
                w.night = DateInterval(start: w.night.start, end: next.night.start)
            }
            candidates[k].windows = w
        }

        var items = candidates
        var deferred: [Day] = []
        if mode == .background {
            // Tight budget: most recent days first, nothing older than the reconcile window.
            let recent = candidates.filter { $0.day >= recentFrom }.sorted { $0.day > $1.day }
            items = Array(recent.prefix(params.backgroundMaxBuilds))
            let kept = Set(items.map(\.day))
            deferred = candidates.map(\.day).filter { !kept.contains($0) }
        }
        return SyncPlan(items: items, historyStart: start, deferred: deferred)
    }

    /// Fingerprints of the current non-heart-rate HealthKit data for every
    /// existing record, using each record's own stored windows.
    public static func fingerprints(for existing: [Day: DayRecord], input: RawDayInput, asOf: Date,
                                    calendar: Calendar, limits: PlausibilityLimits = PlausibilityLimits()) -> [Day: String] {
        var out: [Day: String] = [:]
        for (day, record) in existing {
            let windows = record.windows ?? .nominal(for: day, calendar: calendar)
            out[day] = SourceFingerprint.compute(windows: windows, input: input, asOf: asOf, limits: limits)
        }
        return out
    }
}

/// Per-day acceptance summary for logs and diagnostics. Counts and decisions only.
public enum DayQuality {
    public static func notes(for r: DayRecord, params: ModelParameters = .standard) -> [String] {
        var out: [String] = []
        if r.lnHRV != nil {
            out.append("HRV: \(r.hrvSampleCount) sample(s) \(r.hrvDuringSleep ? "during sleep" : "in fallback window")")
        } else {
            out.append("HRV: none in overnight window - night excluded from HRV baseline")
        }
        if r.sleepingHR != nil {
            out.append("Sleeping HR: \(r.sleepingHRSampleCount) samples")
        } else if r.sleep == nil {
            out.append("Sleeping HR: no sleep detected - excluded")
        } else {
            out.append("Sleeping HR: \(r.sleepingHRSampleCount) < \(params.minSleepHRSamples) samples - excluded")
        }
        out.append(r.sleep == nil ? "Sleep: none attributed to this day" : "Sleep: detected")
        if r.coverageHours >= params.minCoverageHours {
            out.append(String(format: "Load: observed (%.1f h HR coverage)", r.coverageHours))
        } else {
            out.append(String(format: "Load: unobserved (%.1f h < %.0f h coverage) - counted as zero",
                              r.coverageHours, params.minCoverageHours))
        }
        let rejected = HealthInput.allCases.map { r.ingestion[$0] }
        let dup = rejected.reduce(0) { $0 + $1.duplicates }
        let imp = rejected.reduce(0) { $0 + $1.implausible }
        let fut = rejected.reduce(0) { $0 + $1.future }
        if dup + imp + fut > 0 {
            out.append("Rejected samples: \(dup) duplicate, \(imp) implausible, \(fut) future-dated")
        }
        if r.workouts.started > 0 {
            let cov = r.workouts.heartRateCoverage.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
            out.append("Workouts: \(r.workouts.started) started, HR coverage \(cov)")
        }
        return out
    }
}
