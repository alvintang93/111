import AppIntents
import SwiftUI
import WidgetKit
import MarginCore

// MARK: - Configuration

enum WidgetMetric: String, AppEnum {
    case recovery, strain, energy, stress, sleep, hrv, sleepingHR, caffeine, water, hrRecovery, topLift, muscles

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Metric" }
    // Must be a literal: the App Intents metadata extractor reads it at build time.
    static var caseDisplayRepresentations: [WidgetMetric: DisplayRepresentation] = [
        .recovery: "Recovery", .strain: "Strain", .energy: "Energy", .stress: "Stress", .sleep: "Sleep",
        .hrv: "HRV", .sleepingHR: "Sleeping HR", .caffeine: "Caffeine", .water: "Water",
        .hrRecovery: "HR recovery", .topLift: "Top lift", .muscles: "Muscles",
    ]

    var metric: DashboardMetric { DashboardMetric(rawValue: rawValue)! }
}

struct MetricIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Margin metric" }
    static var description: IntentDescription { "Choose the metric to pin." }

    @Parameter(title: "Metric", default: .recovery)
    var metric: WidgetMetric

    @Parameter(title: "Second metric", default: .strain)
    var second: WidgetMetric

    @Parameter(title: "Third metric", default: .energy)
    var third: WidgetMetric
}

// MARK: - Timeline

struct PhoneEntry: TimelineEntry {
    let date: Date
    /// Tiles in the configured order; built from `MarginCore.DashboardTile`, which handles stale and missing data.
    let tiles: [DashboardTile]
    let directive: Directive?
}

struct PhoneProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PhoneEntry {
        PhoneEntry(date: Date(), tiles: [.recovery, .strain, .energy].map { DashboardTile.make($0, brief: nil, now: Date(), calendar: .current) },
                   directive: nil)
    }

    private func entry(_ intent: MetricIntent, at date: Date) -> PhoneEntry {
        let brief = SharedStore.loadBrief()
        let tiles = [intent.metric, intent.second, intent.third].map { m -> DashboardTile in
            m == .topLift || m == .muscles
                ? DashboardTile.makeStrength(m.metric, brief: brief, now: date, calendar: .current, unit: .kg)
                : DashboardTile.make(m.metric, brief: brief, now: date, calendar: .current)
        }
        let current = brief.map { $0.day == Day(date, calendar: .current) } ?? false
        return PhoneEntry(date: date, tiles: tiles, directive: current ? brief?.plan.directive : nil)
    }

    func snapshot(for configuration: MetricIntent, in context: Context) async -> PhoneEntry {
        entry(configuration, at: Date())
    }

    func timeline(for configuration: MetricIntent, in context: Context) async -> Timeline<PhoneEntry> {
        let now = Date()
        var entries = [entry(configuration, at: now)]
        // Blank out at midnight rather than show yesterday's numbers as today's.
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            entries.append(entry(configuration, at: midnight))
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }
}

// MARK: - Views

struct PhoneWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PhoneEntry

    private var first: DashboardTile { entry.tiles[0] }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(first.metric.title) \(first.value)")
        case .accessoryCircular:
            Gauge(value: first.fraction ?? 0) {
                Text(String(first.metric.title.prefix(3)).uppercased())
            } currentValueLabel: {
                Text(first.value)
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(first.metric.title.uppercased()).font(.caption2.bold())
                Text(first.value).font(.title3.bold())
                Text(first.caption).font(.caption2)
            }
        case .systemMedium:
            HStack(spacing: 12) {
                ForEach(Array(entry.tiles.enumerated()), id: \.offset) { _, t in
                    tile(t)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                tile(first)
                if let d = entry.directive {
                    Label(d.title, systemImage: d.symbol).font(.caption.bold()).foregroundStyle(d.color)
                }
            }
        }
    }

    private func tile(_ t: DashboardTile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t.metric.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(t.value).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(t.tone.color)
                .minimumScaleFactor(0.5).lineLimit(1)
            if let f = t.fraction { ProgressView(value: f).tint(t.tone.color) }
            Text(t.caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarginPhoneWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "MarginPhoneMetric", intent: MetricIntent.self, provider: PhoneProvider()) { entry in
            PhoneWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Margin")
        .description("Pin any Margin metric to your home or lock screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct MarginPhoneWidgets: WidgetBundle {
    var body: some Widget {
        MarginPhoneWidget()
    }
}
