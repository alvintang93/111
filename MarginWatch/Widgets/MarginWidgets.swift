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

@main
struct MarginWidgets: WidgetBundle {
    var body: some Widget {
        MarginRecoveryWidget()
    }
}
