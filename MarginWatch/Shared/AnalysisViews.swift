import Charts
import SwiftUI
import MarginCore

/// "Why today": the engine's explanation, line by line.
struct ExplanationView: View {
    let explanation: RecoveryExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(explanation.headline).font(.footnote.weight(.semibold))
            ForEach(explanation.lines, id: \.self) { line in
                Text("• " + line).font(.caption2).foregroundStyle(.secondary)
            }
            if !explanation.drivers.isEmpty {
                Chart(explanation.drivers) { d in
                    BarMark(x: .value("Effect", explanation.comparedWith == nil ? (d.now ?? 0) : d.change),
                            y: .value("Input", d.kind.title), height: .fixed(8))
                        .foregroundStyle((explanation.comparedWith == nil ? (d.now ?? 0) : d.change) >= 0 ? Color.green : Color.orange)
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(explanation.drivers.count) * 18 + 10)
                Text(explanation.comparedWith.map { "Change in each input's contribution since \($0.description)." }
                     ?? "Each input's contribution today.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Stage timeline for one night.
struct HypnogramView: View {
    let stages: [StageSpan]

    private func level(_ s: SleepStage) -> Int {
        switch s {
        case .awake, .inBed: return 3
        case .rem: return 2
        case .core, .asleepUnspecified: return 1
        case .deep: return 0
        }
    }

    private func color(_ s: SleepStage) -> Color {
        switch s {
        case .awake, .inBed: return .orange
        case .rem: return .cyan
        case .core, .asleepUnspecified: return .blue
        case .deep: return .indigo
        }
    }

    var body: some View {
        Chart(stages) { s in
            RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end),
                          yStart: .value("Low", Double(level(s.stage))), yEnd: .value("High", Double(level(s.stage)) + 0.8))
                .foregroundStyle(color(s.stage))
        }
        .chartYAxis {
            AxisMarks(values: [0.4, 1.4, 2.4, 3.4]) { v in
                AxisValueLabel { Text(["Deep", "Core", "REM", "Awake"][min(Int(v.as(Double.self) ?? 0), 3)]).font(.system(size: 9)) }
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 2)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
    }
}

struct SleepHistoryList: View {
    let nights: [SleepHistoryNight]

    var body: some View {
        ForEach(nights.reversed()) { n in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(n.day.description).font(.footnote.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.1f h · score %d", n.summary.asleepHours, n.summary.score)).font(.caption2).monospacedDigit()
                }
                if n.stages.isEmpty {
                    Text("No stage timeline (recorded before this version, or no stages from the source).")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    HypnogramView(stages: n.stages).frame(height: 70)
                }
                Text(String(format: "Deep %.0f · REM %.0f · core %.0f · awake %.0f min",
                            n.summary.deepMinutes, n.summary.remMinutes, n.summary.coreMinutes + n.summary.unspecifiedMinutes, n.summary.awakeMinutes))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(8)
            .glassCard(cornerRadius: 14)
        }
    }
}

/// One workout: heart-rate curve coloured by zone, time in zones, load and recovery.
struct WorkoutAnalysisView: View {
    let entry: ActivityEntry

    private let zoneColors: [Color] = [.gray, .blue, .green, .yellow, .orange, .red]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title).font(.headline)
            Text("\(entry.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(entry.end.timeIntervalSince(entry.start) / 60)) min")
                .font(.caption2).foregroundStyle(.secondary)
            if let a = entry.analysis {
                if !a.curve.isEmpty {
                    Chart(a.curve) { p in
                        PointMark(x: .value("Min", p.seconds / 60), y: .value("bpm", p.bpm))
                            .symbolSize(10)
                            .foregroundStyle(p.afterEnd ? Color.gray : zoneColors[min(p.zone, 5)])
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 90)
                    if a.curve.contains(where: \.afterEnd) {
                        Text("Grey points are the recovery after the workout ended.").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No heart-rate curve (recorded before this version, or no heart rate during the workout).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    ForEach(1..<6) { z in
                        VStack(spacing: 1) {
                            Text("\(Int(a.zoneMinutes[z].rounded()))").font(.caption2).monospacedDigit()
                            Rectangle().fill(zoneColors[z]).frame(height: 3)
                            Text("Z\(z)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                MetricRowLine(label: "Load (TRIMP)", value: String(format: "%.0f", a.load))
                MetricRowLine(label: "Strain on its own", value: "\(a.strain)")
                if let f = a.focus { MetricRowLine(label: "Focus", value: f.title) }
            } else {
                Text("No Health workout data: logged in Margin only.").font(.caption2).foregroundStyle(.secondary)
            }
            if let h = entry.health {
                if let avg = h.averageHR { MetricRowLine(label: "Average / peak HR", value: String(format: "%.0f / %.0f", avg, h.peakHR ?? avg)) }
                if let r = h.recovery1 { MetricRowLine(label: "1-min recovery", value: String(format: "%.0f bpm", r)) }
                if let r2 = h.drop120 { MetricRowLine(label: "2-min recovery", value: String(format: "%.0f bpm", r2)) }
            }
            if let s = entry.strength {
                MetricRowLine(label: "Sets", value: "\(s.sets.filter { !$0.warmup }.count)")
            }
            Text("Splits need distance samples and are not shown yet.").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

/// A label/value row usable on both platforms.
struct MetricRowLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.footnote)
    }
}
