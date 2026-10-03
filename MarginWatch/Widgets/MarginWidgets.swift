import SwiftUI
import WidgetKit
import MarginCore

struct BriefEntry: TimelineEntry {
    let date: Date
    let brief: DailyBrief?

    /// Nil when the saved brief is from a previous day: stale scores are never shown.
    var current: DailyBrief? {
        guard let b = brief, b.isCurrent(now: date) else { return nil }
        return b
    }
}

struct BriefProvider: TimelineProvider {
    func placeholder(in context: Context) -> BriefEntry {
        BriefEntry(date: Date(), brief: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefEntry) -> Void) {
        completion(BriefEntry(date: Date(), brief: SharedStore.loadBrief()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefEntry>) -> Void) {
        let now = Date()
        let brief = SharedStore.loadBrief()
        var entries = [BriefEntry(date: now, brief: brief)]
        // Add an entry at midnight so yesterday's score blanks out on its own.
        let cal = Calendar.current
        if let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            entries.append(BriefEntry(date: midnight, brief: brief))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct MarginWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BriefEntry

    private var score: Int? { entry.current?.recovery.score }
    private var color: Color { entry.current?.recovery.band.color ?? .gray }
    private var scoreText: String { score.map { "\($0)" } ?? "–" }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        case .accessoryCorner:
            corner
        default:
            circular
        }
    }

    private var circular: some View {
        Gauge(value: Double(score ?? 0), in: 0...100) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(scoreText)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(color)
    }

    private var corner: some View {
        Text(scoreText)
            .font(.title3.bold())
            .foregroundStyle(color)
            .widgetLabel {
                Gauge(value: Double(score ?? 0), in: 0...100) {
                    Text("REC")
                }
                .tint(color)
            }
    }

    private var inline: some View {
        if let b = entry.current {
            return Text("\(scoreText) · \(b.plan.directive.title)")
        }
        return Text("Margin · open app")
    }

    @ViewBuilder
    private var rectangular: some View {
        if let b = entry.current {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("REC \(scoreText)").font(.headline).foregroundStyle(color)
                    Spacer()
                    Text(b.plan.directive.title).font(.caption.bold()).foregroundStyle(b.plan.directive.color)
                }
                if let lo = b.plan.targetLow, let hi = b.plan.targetHigh {
                    Text("Load \(Fmt.load(b.load.todayLoad)) / \(Fmt.load(lo))–\(Fmt.load(hi))")
                        .font(.caption)
                } else {
                    Text("Load \(Fmt.load(b.load.todayLoad))").font(.caption)
                }
                if let flag = b.recovery.flags.first {
                    Label(flag.title, systemImage: flag.symbol).font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(b.recovery.confidence.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading) {
                Text("Margin").font(.headline)
                Text("Open to update").font(.caption).foregroundStyle(.secondary)
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
        .configurationDisplayName("Recovery")
        .description("Recovery score, directive and today's load target.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct MarginWidgets: WidgetBundle {
    var body: some Widget {
        MarginRecoveryWidget()
    }
}
