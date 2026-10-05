import SwiftUI
import WidgetKit
import MarginCore

struct BriefEntry: TimelineEntry {
    let date: Date
    /// Rendering is fully determined by `MarginCore.ComplicationState`, which is
    /// unit-tested for every state (score, calibrating, pending, unavailable, stale).
    let state: ComplicationState
}

struct BriefProvider: TimelineProvider {
    func placeholder(in context: Context) -> BriefEntry {
        BriefEntry(date: Date(), state: ComplicationState.make(brief: nil, now: Date(), calendar: .current))
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefEntry) -> Void) {
        let now = Date()
        completion(BriefEntry(date: now, state: ComplicationState.make(brief: SharedStore.loadBrief(), now: now,
                                                                        calendar: .current)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefEntry>) -> Void) {
        let now = Date()
        let cal = Calendar.current
        let brief = SharedStore.loadBrief()
        var entries = [BriefEntry(date: now, state: ComplicationState.make(brief: brief, now: now, calendar: cal))]
        // Re-evaluate at midnight so yesterday's score blanks out without the app running.
        if let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            entries.append(BriefEntry(date: midnight, state: ComplicationState.make(brief: brief, now: midnight, calendar: cal)))
        }
        let next = now.addingTimeInterval(30 * 60)
        var beat = SharedStore.loadHeartbeat() ?? WidgetHeartbeat()
        beat.lastTimelineAt = now
        beat.nextRefreshRequested = next
        beat.lastKind = entries[0].state.kind
        beat.briefDecoded = brief != nil
        beat.timelines += 1
        SharedStore.saveHeartbeat(beat)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

struct MarginWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BriefEntry

    private var s: ComplicationState { entry.state }
    private var color: Color { s.kind == .score ? s.band.color : .gray }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            Text(s.inline)
        case .accessoryCorner:
            corner
        default:
            circular
        }
    }

    private var circular: some View {
        Gauge(value: s.gaugeFraction, in: 0...1) {
            Image(systemName: s.kind == .score ? "heart.fill" : "hourglass")
        } currentValueLabel: {
            Text(s.kind == .calibrating ? "CAL" : s.scoreText)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(color)
    }

    private var corner: some View {
        Text(s.kind == .calibrating ? "CAL" : s.scoreText)
            .font(.title3.bold())
            .foregroundStyle(color)
            .widgetLabel {
                Gauge(value: s.gaugeFraction, in: 0...1) {
                    Text("REC")
                }
                .tint(color)
            }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(s.headline).font(.headline).foregroundStyle(color)
                Spacer()
                if let d = s.directive, s.kind == .score {
                    Text(ComplicationState.directiveTitle(d)).font(.caption.bold()).foregroundStyle(d.color)
                }
            }
            Text(s.detail).font(.caption)
            if !s.footnote.isEmpty {
                Text(s.footnote)
                    .font(.caption2)
                    .foregroundStyle(s.footnoteIsWarning ? Color.orange : Color.secondary)
            }
        }
    }
}

struct MarginRecoveryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MarginRecovery", provider: BriefProvider()) { entry in
            MarginWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Readiness")
        .description("Readiness score, recommendation and today's load target.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

// MARK: - Metric complications (strain, energy, stress, sleep)

struct MetricEntry: TimelineEntry {
    let date: Date
    /// Rendering is fully determined by `MarginCore.DashboardTile`, which is
    /// unit-tested for stale and missing states.
    let tile: DashboardTile
}

struct MetricProvider: TimelineProvider {
    let metric: DashboardMetric

    private func entry(_ brief: DailyBrief?, at date: Date) -> MetricEntry {
        MetricEntry(date: date, tile: DashboardTile.make(metric, brief: brief, now: date, calendar: .current))
    }

    func placeholder(in context: Context) -> MetricEntry { entry(nil, at: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (MetricEntry) -> Void) {
        completion(entry(SharedStore.loadBrief(), at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MetricEntry>) -> Void) {
        let now = Date()
        let cal = Calendar.current
        let brief = SharedStore.loadBrief()
        var entries = [entry(brief, at: now)]
        // At midnight the tile blanks out rather than showing yesterday's value as today's.
        if let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            entries.append(entry(brief, at: midnight))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct MetricWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MetricEntry

    private var t: DashboardTile { entry.tile }
    private var color: Color { t.available ? t.tone.color : .gray }
    private var short: String {
        switch t.metric {
        case .strain: return "STR"
        case .energy: return "NRG"
        case .stress: return "STS"
        case .sleep: return "SLP"
        default: return String(t.metric.title.prefix(3)).uppercased()
        }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(t.metric.title) \(t.value)")
        case .accessoryCorner:
            Text(t.value)
                .font(.title3.bold())
                .foregroundStyle(color)
                .widgetLabel {
                    Gauge(value: t.fraction ?? 0, in: 0...1) { Text(short) }
                        .tint(color)
                }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(t.metric.title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
                Text(t.value).font(.title2.bold()).foregroundStyle(color).monospacedDigit()
                Text(t.caption).font(.caption2)
            }
        default:
            Gauge(value: t.fraction ?? 0, in: 0...1) {
                Text(short)
            } currentValueLabel: {
                Text(t.value)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(color)
        }
    }
}

enum MetricWidget {
    static func configuration(metric: DashboardMetric, kind: String, summary: String) -> some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MetricProvider(metric: metric)) { entry in
            MetricWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(metric.title)
        .description(summary)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct StrainWidget: Widget {
    var body: some WidgetConfiguration {
        MetricWidget.configuration(metric: .strain, kind: "MarginStrain", summary: "Today's strain, 0–100, with your target.")
    }
}

struct EnergyWidget: Widget {
    var body: some WidgetConfiguration {
        MetricWidget.configuration(metric: .energy, kind: "MarginEnergy", summary: "Energy bank as of the last sync.")
    }
}

struct StressWidget: Widget {
    var body: some WidgetConfiguration {
        MetricWidget.configuration(metric: .stress, kind: "MarginStress", summary: "Latest hourly stress level.")
    }
}

struct SleepWidget: Widget {
    var body: some WidgetConfiguration {
        MetricWidget.configuration(metric: .sleep, kind: "MarginSleep", summary: "Last night's sleep score and time asleep.")
    }
}

@main
struct MarginWidgets: WidgetBundle {
    var body: some Widget {
        MarginRecoveryWidget()
        StrainWidget()
        EnergyWidget()
        StressWidget()
        SleepWidget()
    }
}
