import Charts
import SwiftUI
import MarginCore

// MARK: - Drivers

/// Score attribution: each component's value, baseline, z-score and weight.
struct DriversView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let b = model.brief, b.isCurrent() {
                    if b.recovery.components.isEmpty {
                        Text("No components available yet.").font(.footnote)
                    }
                    ForEach(b.recovery.components) { c in
                        ComponentRow(component: c)
                    }
                    MetricRow(label: "Composite", value: Fmt.signed(b.recovery.composite, digits: 2))
                    MetricRow(label: "vs your typical day", value: Fmt.signed(b.recovery.relativeZ, digits: 2) + "σ")
                    MetricRow(label: "Calibration days", value: "\(b.recovery.calibrationDays)")
                    MetricRow(label: "HRV baseline nights", value: "\(b.recovery.baselineDays)")
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Drivers")
    }
}

struct ComponentRow: View {
    let component: Component

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(component.kind.title).font(.footnote.weight(.semibold))
                Spacer()
                Text(component.kind.format(component.value)).font(.footnote).monospacedDigit()
            }
            ZBar(z: component.z)
            HStack {
                if let base = component.baseline {
                    Text("base \(component.kind.format(base))")
                }
                Spacer()
                Text("\(Fmt.signed(component.z))σ · w\(Int((component.weight * 100).rounded()))%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// Centred bar for an oriented z-score in [-3, 3]; right/green is better.
struct ZBar: View {
    let z: Double

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let w = half * CGFloat(min(abs(z), 3) / 3)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Rectangle().fill(Color.white.opacity(0.4)).frame(width: 1).offset(x: half)
                Capsule()
                    .fill(z >= 0 ? Color.green : Color.red)
                    .frame(width: max(w, 2))
                    .offset(x: z >= 0 ? half : half - w)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Sleep

struct SleepView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let b = model.brief, b.isCurrent(), let s = b.sleep {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.hours(s.asleepHours)).font(.title2.bold()).monospacedDigit()
                        Spacer()
                        Text("\(s.score)").font(.title3.bold()).foregroundStyle(.indigo)
                    }
                    MetricRow(label: "Need", value: Fmt.hours(s.needHours))
                    MetricRow(label: "Performance", value: String(format: "%.0f%%", s.performance * 100))
                    StageBar(summary: s)
                    MetricRow(label: "Efficiency", value: s.efficiency.map { String(format: "%.0f%%", $0 * 100) } ?? "–")
                    MetricRow(label: "Midpoint SD (7n)", value: s.midpointSDMinutes.map { String(format: "%.0f min", $0) } ?? "–")
                    MetricRow(label: "7-night debt", value: Fmt.hours(s.debtHours),
                              tint: s.debtHours >= 5 ? .orange : .primary)
                    MetricRow(label: "Tonight's need", value: Fmt.hours(s.tonightNeedHours), tint: .indigo)
                    Text("\(s.onset.formatted(date: .omitted, time: .shortened)) – \(s.wake.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if model.brief?.isCurrent() == true {
                    Text("No sleep recorded last night.").font(.footnote)
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Sleep")
    }
}

struct StageBar: View {
    let summary: SleepSummary

    var body: some View {
        let parts: [(String, Double, Color)] = [
            ("Deep", summary.deepMinutes, .indigo),
            ("Core", summary.coreMinutes + summary.unspecifiedMinutes, .blue),
            ("REM", summary.remMinutes, .cyan),
            ("Awake", summary.awakeMinutes, .orange),
        ]
        let total = max(parts.reduce(0) { $0 + $1.1 }, 1)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: geo.size.width * p.1 / total)
                    }
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                ForEach(parts, id: \.0) { p in
                    Text("\(p.0) \(Int(p.1.rounded()))").font(.system(size: 10)).foregroundStyle(p.2)
                }
            }
        }
    }
}

// MARK: - Load

struct LoadView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let b = model.brief, b.isCurrent() {
                    if let s = b.strain { StrainCard(strain: s) }
                    LoadTargetBar(load: b.load.todayLoad, low: b.plan.targetLow, high: b.plan.targetHigh)
                    MetricRow(label: "Ceiling today", value: Fmt.load(b.plan.ceiling))
                    MetricRow(label: "ATL (7d)", value: Fmt.load(b.load.atl))
                    MetricRow(label: "CTL (42d)", value: Fmt.load(b.load.ctl))
                    MetricRow(label: "Form (CTL−ATL)", value: Fmt.signed(b.load.tsb, digits: 0))
                    MetricRow(label: "ACWR", value: Fmt.ratio(b.load.acwr),
                              tint: (b.load.acwr ?? 1) > 1.5 ? .red : ((b.load.acwr ?? 1) > 1.3 ? .orange : .primary))
                    if b.load.unobservedDaysLast28 > 0 {
                        MetricRow(label: "Unworn days (28d)", value: "\(b.load.unobservedDaysLast28)", tint: .orange)
                    }
                    SectionHeader(text: "Zones today (min)")
                    ZoneRow(minutes: b.load.todayZoneMinutes)
                    SectionHeader(text: "14-day load / CTL")
                    Chart(b.history) { p in
                        if let l = p.load {
                            BarMark(x: .value("Day", p.day.description), y: .value("Load", l))
                                .foregroundStyle(Color.orange.opacity(0.7))
                        }
                        if let c = p.ctl {
                            LineMark(x: .value("Day", p.day.description), y: .value("CTL", c))
                                .foregroundStyle(.white)
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 80)
                    Text("HRmax \(Int(b.hrMaxUsed)) · HRrest \(Int(b.hrRestUsed.rounded()))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let hrr = b.heartRateRecovery {
                        SectionHeader(text: "Heart-rate recovery")
                        HeartRateRecoverySection(summary: hrr)
                    }
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Load")
    }
}

struct ZoneRow: View {
    let minutes: [Double]
    private let colors: [Color] = [.gray, .blue, .green, .yellow, .orange, .red]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(minutes.enumerated()), id: \.offset) { idx, m in
                VStack(spacing: 1) {
                    Text("\(Int(m.rounded()))").font(.caption2).monospacedDigit()
                    Rectangle().fill(colors[min(idx, colors.count - 1)]).frame(height: 3)
                }
            }
        }
    }
}

// MARK: - Trends

struct TrendsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let b = model.brief, b.isCurrent() {
                    SectionHeader(text: "Recovery, 14 days")
                    Chart(b.history) { p in
                        if let s = p.recoveryScore {
                            BarMark(x: .value("Day", p.day.description), y: .value("Recovery", s))
                                .foregroundStyle(band(for: s).color)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartYScale(domain: 0...100)
                    .frame(height: 80)
                    SectionHeader(text: "HRV (ms), 14 days")
                    Chart(b.history) { p in
                        if let h = p.hrvMs {
                            LineMark(x: .value("Day", p.day.description), y: .value("HRV", h))
                                .foregroundStyle(.green)
                            PointMark(x: .value("Day", p.day.description), y: .value("HRV", h))
                                .foregroundStyle(.green)
                                .symbolSize(12)
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 80)
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Trends")
    }

    private func band(for score: Int) -> RecoveryBand {
        let p = ModelParameters.standard
        return score >= p.primedThreshold ? .primed : (score <= p.depletedThreshold ? .depleted : .steady)
    }
}
