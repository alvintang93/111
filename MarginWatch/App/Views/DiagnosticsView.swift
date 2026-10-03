import SwiftUI
import MarginCore

/// Developer diagnostics. Every value is read from production state
/// (`AppModel.brief` and its `audit`, the cached records, runtime status and
/// logs); nothing is recalculated here.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if let b = model.brief {
                statusSection(b)
                permissionsSection(b)
                dataSection(b)
                scoringSection(b)
                traceSection(b)
                distributionSection(b)
            } else {
                Section("Status") {
                    Text("No brief computed yet.").font(.footnote)
                }
            }
            backgroundSection
            daysSection
            eventsSection
            Section {
                Button("Sync now") { Task { await model.sync(mode: .foreground) } }
                    .disabled(model.isRefreshing)
                Button("Reload widget heartbeat") { model.refreshHeartbeat() }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { model.refreshHeartbeat() }
    }

    // MARK: Sections

    private func statusSection(_ b: DailyBrief) -> some View {
        let r = b.recovery
        let c = r.calibration
        return Section("Score status") {
            Group {
                    KV("Day", b.day.description)
                    KV("Status", r.status.label, tint: r.status.color)
                    Text(r.statusDetail).font(.caption2).foregroundStyle(.secondary)
                    KV("Calibration", c.stage.rawValue)
                    KV("HRV nights (valid calibration days)", "\(c.hrvNights)/\(c.hrvNightsRequired)")
                    KV("Sleeping-HR nights", "\(c.sleepingHRNights)")
            }
            Group {
                    KV("Score-scale days", "\(c.compositeDays)/\(c.compositeDaysRequired)")
                    KV("Missing tonight", r.missingInputs.isEmpty ? "none" : r.missingInputs.map(\.title).joined(separator: ", "))
                    KV("Computed", ts(b.generatedAt))
                    KV("Data synced", ts(b.dataSyncedAt))
                    KV("Engine", MarginCoreInfo.engineVersion)
            }
        }
    }

    private func permissionsSection(_ b: DailyBrief) -> some View {
        Section("Health access") {
            KV("Request status", model.runtime.authorizationRequestStatus ?? "unknown")
            KV("Last requested", ts(model.runtime.authorizationRequestedAt))
            Text("HealthKit never tells an app whether read access was granted. A type with no data below means access is off OR nothing was recorded.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(b.audit.inputs) { i in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(i.input.title).font(.footnote.weight(.semibold))
                        Spacer()
                        Text(i.daysWithDataInWindow == 0 ? "NO DATA" : "data seen")
                            .font(.caption2)
                            .foregroundStyle(i.daysWithDataInWindow == 0 ? Color.orange : Color.green)
                    }
                    Text("days with data: \(i.daysWithDataLast7)/7, \(i.daysWithDataInWindow)/\(i.windowDays)")
                    Text("latest sample: \(ts(i.latestSample))")
                    if i.duplicates + i.implausible + i.future > 0 {
                        Text("rejected: \(i.duplicates) dup, \(i.implausible) implausible, \(i.future) future")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
            }
        }
    }

    private func dataSection(_ b: DailyBrief) -> some View {
        let a = b.audit
        let earliest = a.inputs.compactMap(\.earliestSample).min()
        let latest = a.inputs.compactMap(\.latestSample).max()
        return Section("Data") {
            Group {
                KV("Last successful sync", ts(model.runtime.lastSuccessfulSync))
                KV("Last sync mode / days built", "\(model.runtime.lastSyncMode?.rawValue ?? "-") / \(model.runtime.lastSyncDaysBuilt.map { "\($0)" } ?? "-")")
                KV("Earliest sample (window)", ts(earliest))
                KV("Latest sample", ts(latest))
                KV("Cached days", "\(a.recordCount) (\(a.earliestRecordDay?.description ?? "-") ... \(a.latestRecordDay?.description ?? "-"))")
            }
            Group {
                KV("Workouts 7d / 28d", "\(a.workoutsLast7) / \(a.workoutsLast28)")
                KV("Latest workout end", ts(a.latestWorkoutEnd))
                KV("Workout HR coverage 7d", a.workoutHRCoverageLast7.map { String(format: "%.0f%%", $0 * 100) } ?? "-")
                KV("Time zones (14d)", a.recentTimeZones.joined(separator: ", "))
                KV("HRmax", "\(Int(b.hrMaxUsed)) - \(a.hrMaxSource)")
                KV("HRrest", "\(Int(b.hrRestUsed.rounded())) - \(a.hrRestSource)")
            }
        }
    }

    private func scoringSection(_ b: DailyBrief) -> some View {
        let r = b.recovery
        let t = b.audit.thresholds
        return Section("Scoring") {
            ForEach(r.components) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.kind.title).font(.footnote.weight(.semibold))
                    Text("value \(c.kind.format(c.value)), baseline \(c.baseline.map { c.kind.format($0) } ?? "-")")
                    Text("raw z \(Fmt.signed(c.rawZ, digits: 2)), used z \(Fmt.signed(c.z, digits: 2))")
                    Text(String(format: "weight %.3f, contribution %+.3f", c.weight, c.contribution))
                }
                .font(.caption2)
            }
            ForEach(b.audit.baselines) { bl in
                KV("Baseline \(bl.kind.title)", "\(bl.kind.format(bl.center)) (n=\(bl.count), scale \(String(format: "%.3f", bl.scale)))")
            }
            KV("Composite", Fmt.signed(r.composite, digits: 3))
            KV("vs typical day", Fmt.signed(r.relativeZ, digits: 2))
            KV("Score", r.score.map { "\($0)" } ?? "withheld")
            KV("Recommendation", b.plan.directive.title, tint: b.plan.directive.color)
            KV("Thresholds", "Push >= \(t.primedScore), Recover <= \(t.recoverScore) or <= \(t.depletedScore)+confirmation")
            KV("Vitals / trend / spike", String(format: "z >= %.1f / SWC %.1f / ACWR > %.2f", t.elevatedVitalsZ, t.hrvTrendSWC, t.loadSpikeACWR))
            KV("Sleep debt / ceiling", String(format: "%.0f h / ACWR %.2f", t.sleepDebtHours, t.acwrCeiling))
            KV("Weights", t.weights.map { "\($0.kind.title) \(String(format: "%.3f", $0.weight))" }.joined(separator: ", "))
        }
    }

    private func traceSection(_ b: DailyBrief) -> some View {
        Section("Why: \(b.plan.directive.title)") {
            ForEach(b.plan.trace) { step in
                VStack(alignment: .leading, spacing: 1) {
                    Label(step.rule, systemImage: step.passed ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(step.passed ? Color.green : Color.secondary)
                        .font(.caption2.weight(.semibold))
                    Text(step.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(b.plan.reasons, id: \.self) { Text($0).font(.caption2) }
        }
    }

    private func distributionSection(_ b: DailyBrief) -> some View {
        let d = b.audit.distribution
        return Section("Distribution (\(d.days)d, recomputed)") {
            ForEach(d.directives) { e in KV(e.key, "\(e.count)") }
            KV("Score mean / SD", "\(Fmt.signed(d.scoreMean, digits: 1)) / \(Fmt.signed(d.scoreSD, digits: 1))")
            KV("Histogram 0-99", d.scoreHistogram.map { "\($0)" }.joined(separator: " "))
            ForEach(d.components) { c in
                KV("z \(c.kind.title)", "n \(c.n), mean \(Fmt.signed(c.mean, digits: 2)), sd \(Fmt.signed(c.sd, digits: 2))")
            }
            Text("As issued (\(model.decisionLog.entries.count)d)").font(.caption2.weight(.semibold))
            ForEach(model.decisionLog.directiveCounts()) { e in KV(e.key, "\(e.count)") }
        }
    }

    private var backgroundSection: some View {
        let rt = model.runtime
        let hb = model.widgetHeartbeat
        return Section("Background & complication") {
            Group {
                KV("Last foreground sync", ts(rt.lastForegroundSync))
                KV("Last background run (executed)", ts(rt.lastBackgroundTaskRun))
                KV("Background runs logged", "\(rt.backgroundRuns.count)")
                ForEach(Array(rt.backgroundRuns.suffix(5).reversed().enumerated()), id: \.offset) { _, d in
                    Text(ts(d)).font(.caption2)
            }
            KV("Last background request", ts(rt.lastBackgroundRequestAt))
            KV("Requested for", ts(rt.lastBackgroundPreferredDate))
            if let e = rt.lastBackgroundScheduleError { KV("Request error", e, tint: .orange) }
            }
            Group {
                KV("App Group", SharedStore.groupAvailable ? "available" : "UNAVAILABLE", tint: SharedStore.groupAvailable ? .green : .red)
                KV("Widget reload requested", ts(rt.lastWidgetReloadRequestAt))
                KV("Widget timeline generated", ts(hb?.lastTimelineAt))
                KV("Widget next refresh requested", ts(hb?.nextRefreshRequested))
                KV("Widget state / saw brief", "\(hb?.lastKind?.rawValue ?? "-") / \(hb.map { $0.briefDecoded ? "yes" : "no" } ?? "-")")
                KV("Widget timelines", "\(hb?.timelines ?? 0)")
                KV("Last sync error", rt.lastSyncError.map { "\($0) (\(ts(rt.lastSyncErrorAt)))" } ?? "none",
                   tint: rt.lastSyncError == nil ? .primary : .orange)
                KV("Last persistence error", rt.lastPersistError ?? "none", tint: rt.lastPersistError == nil ? .primary : .orange)
            }
        }
    }

    private var daysSection: some View {
        Section("Recent days") {
            ForEach(model.recentRecords, id: \.day) { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.day.description).font(.footnote.weight(.semibold))
                    ForEach(DayQuality.notes(for: r), id: \.self) { Text($0) }
                    Text("built \(ts(r.builtAt)), tz \(r.windows?.timeZoneID ?? "-")")
                    if let w = r.windows {
                        Text("night \(hm(w.night.start))-\(hm(w.night.end)), day \(hm(w.activity.start))-\(hm(w.activity.end))")
                    }
                    if let s = r.sleep {
                        Text("main sleep \(hm(s.mainOnset))-\(hm(s.mainWake))")
                    }
                }
                .font(.caption2)
            }
        }
    }

    private var eventsSection: some View {
        Section("Events (newest first)") {
            ForEach(Array(model.events.suffix(40).reversed().enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(hm(e.at)) \(e.stage.rawValue) \(e.level.rawValue)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(e.level == .error ? Color.red : (e.level == .warning ? Color.orange : Color.secondary))
                    Text(e.message).font(.caption2)
                }
            }
        }
    }

    // MARK: Formatting

    private func ts(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
    }

    private func hm(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }
}

/// Label/value row that wraps long values.
struct KV: View {
    let key: String
    let value: String
    let tint: Color

    init(_ key: String, _ value: String, tint: Color = .primary) {
        self.key = key
        self.value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(key).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2).foregroundStyle(tint)
        }
    }
}

extension HealthInput {
    var title: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .hrv: return "Heart rate variability"
        case .restingHR: return "Resting heart rate"
        case .respiratoryRate: return "Respiratory rate"
        case .wristTemperature: return "Wrist temperature"
        case .sleep: return "Sleep"
        case .workouts: return "Workouts"
        }
    }
}
