import Charts
import SwiftUI
import MarginCore

/// Every health metric with its state, latest value and change from your baseline.
struct HealthMetricsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let reports = model.brief?.healthMetrics, model.brief?.isCurrent() == true {
                    ForEach(reports) { r in
                        NavigationLink {
                            MetricDetailView(kind: r.kind)
                        } label: {
                            MetricRowCard(report: r)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Values come from Apple Health. Margin rejects implausible readings and never fills gaps.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Health")
    }
}

struct MetricRowCard: View {
    let report: MetricReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(report.kind.title, systemImage: report.kind.symbol).font(.caption2.weight(.semibold))
                Spacer()
                Image(systemName: report.state.symbol).foregroundStyle(report.state.color).font(.caption2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(report.kind.format(report.current?.value)).font(.title3.bold()).monospacedDigit()
                if report.current != nil { Text(report.kind.unitLabel).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
            }
            Text(report.changeLine ?? report.state.label)
                .font(.system(size: 11))
                .foregroundStyle(report.changeLine == nil ? report.state.color : report.changeColor)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }
}

/// Metric → current → change vs baseline → trend → readings → history → context → source → method.
struct MetricDetailView: View {
    @EnvironmentObject private var model: AppModel
    let kind: HealthMetricKind

    private var report: MetricReport? { model.brief?.healthMetrics?.first { $0.kind == kind } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let r = report {
                    MetricHeader(report: r)
                    if r.history.count >= 2 { MetricChart(report: r).frame(height: 80) }
                    MetricTrends(report: r)
                    if !r.readings.isEmpty {
                        SectionHeader(text: r.kind == .hrv ? "Last night's readings" : "Latest readings")
                        ForEach(r.readings) { o in ObservationRow(kind: r.kind, obs: o, showTime: true) }
                    }
                    SectionHeader(text: "History")
                    if r.history.isEmpty {
                        Text("No readings yet.").font(.caption2)
                    }
                    ForEach(r.history.suffix(14).reversed()) { o in ObservationRow(kind: r.kind, obs: o, showTime: !r.kind.hasRollingBaseline) }
                    ForEach(r.notes, id: \.self) { n in Text(n).font(.caption2).foregroundStyle(.secondary) }
                    if !r.sources.isEmpty {
                        Text("Sources: \(r.sources.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                    }
                    SectionHeader(text: "How it's measured")
                    Text(r.methodology).font(.caption2).foregroundStyle(.secondary)
                    if let b = r.baseline { Text("Baseline: \(b.method), \(b.count) days.").font(.caption2).foregroundStyle(.secondary) }
                } else {
                    EmptyState()
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(kind.title)
    }
}

struct MetricHeader: View {
    let report: MetricReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(report.kind.format(report.current?.value)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                if report.current != nil { Text(report.kind.unitLabel).font(.footnote).foregroundStyle(.secondary) }
            }
            if let c = report.current {
                Text("\(c.date.formatted(date: .abbreviated, time: .shortened))\(c.source.map { " · \($0)" } ?? "")\(c.count.map { " · \($0) reading\($0 == 1 ? "" : "s")" } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let line = report.changeLine {
                Text(line).font(.footnote).foregroundStyle(report.changeColor)
            }
            if let z = report.z {
                Text(String(format: "%+.1f robust SD from your baseline", z)).font(.caption2).foregroundStyle(.secondary)
            }
            Label(report.state.label, systemImage: report.state.symbol).font(.caption2).foregroundStyle(report.state.color)
            if !report.stateDetail.isEmpty { Text(report.stateDetail).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, tint: report.state == .available ? nil : report.state.color)
    }
}


struct MetricTrends: View {
    let report: MetricReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(report.trends) { t in
                HStack {
                    Text("\(t.days) d").font(.caption2.weight(.semibold)).frame(width: 30, alignment: .leading)
                    if t.sufficient {
                        Text(t.change.map { "\(report.kind.formatSigned($0)) \(report.kind.unitLabel)" } ?? "–").font(.caption2).monospacedDigit()
                        Spacer()
                        Text(t.slopePerWeek.map { "\(report.kind.formatSigned($0))/wk" } ?? "").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("\(t.n) of \(MetricMath.minimumCount(days: t.days, sporadic: !report.kind.hasRollingBaseline)) readings needed")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }
}


/// Today's "what is my body doing": only the readings at least 1 SD from your baseline.
struct BodyDeviationsView: View {
    let reports: [MetricReport]

    var body: some View {
        let watched: [HealthMetricKind] = [.hrv, .sleepingHR, .respiratoryRate, .wristTemperature, .spo2]
        let notable = reports.filter { watched.contains($0.kind) && $0.isNotable }
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(text: "Body")
            if notable.isEmpty {
                Text(reports.contains { watched.contains($0.kind) && $0.state == .available }
                     ? "Overnight readings are within your usual range."
                     : "Overnight readings aren't available yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(notable) { r in
                NavigationLink { MetricDetailView(kind: r.kind) } label: {
                    HStack {
                        Image(systemName: r.kind.symbol)
                        Text(r.kind.title).font(.caption2)
                        Spacer()
                        Text(r.changeLine ?? "").font(.system(size: 10)).foregroundStyle(r.changeColor).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .glassCapsule(tint: r.changeColor == .secondary ? nil : r.changeColor)
                }
                .buttonStyle(.plain)
            }
            NavigationLink { HealthMetricsView() } label: {
                Text("All health metrics").font(.caption2)
            }
        }
    }
}
