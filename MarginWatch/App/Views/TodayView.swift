import SwiftUI
import MarginCore

struct TodayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let b = model.brief, b.isCurrent() {
                    RecoveryRing(score: b.recovery.score, band: b.recovery.band)
                        .frame(width: 118, height: 118)
                    DirectiveRow(plan: b.plan)
                    LoadTargetBar(load: b.load.todayLoad, low: b.plan.targetLow, high: b.plan.targetHigh)
                    if !b.recovery.flags.isEmpty {
                        FlagList(flags: b.recovery.flags)
                    }
                    ForEach(b.plan.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    StatusBadge(recovery: b.recovery)
                } else {
                    EmptyState()
                }
                if let status = model.status, model.brief != nil {
                    Text(status).font(.caption2).foregroundStyle(.orange)
                }
                Button {
                    Task { await model.sync(mode: .foreground) }
                } label: {
                    Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .modifier(PrimaryDoubleTap())
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Today")
        .containerBackground((model.brief?.recovery.band.color ?? .gray).gradient.opacity(0.35), for: .tabView)
    }
}

struct RecoveryRing: View {
    let score: Int?
    let band: RecoveryBand

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 12)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(band.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map { "\($0)" } ?? "–")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("RECOVERY").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery \(score.map { "\($0)" } ?? "unavailable")")
    }
}

struct DirectiveRow: View {
    let plan: Plan

    var body: some View {
        HStack {
            Image(systemName: plan.directive.symbol)
            Text(plan.directive.title).font(.headline)
            Spacer()
            if let lo = plan.targetLow, let hi = plan.targetHigh {
                Text("\(Fmt.load(lo))–\(Fmt.load(hi))").font(.footnote).monospacedDigit()
            }
        }
        .foregroundStyle(plan.directive.color)
    }
}

/// Today's training load (TRIMP) against the recommended range.
struct LoadTargetBar: View {
    let load: Double?
    let low: Double?
    let high: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Load today").foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.load(load)).monospacedDigit()
            }
            .font(.footnote)
            GeometryReader { geo in
                let scale = max(high ?? 0, load ?? 0, 1) * 1.15
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    if let lo = low, let hi = high {
                        Capsule().fill(Color.green.opacity(0.35))
                            .frame(width: max(geo.size.width * (hi - lo) / scale, 2))
                            .offset(x: geo.size.width * lo / scale)
                    }
                    Capsule().fill(Color.white)
                        .frame(width: max(geo.size.width * (load ?? 0) / scale, 3))
                }
            }
            .frame(height: 8)
        }
    }
}

struct FlagList: View {
    let flags: [Flag]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(flags, id: \.self) { f in
                Label(f.title, systemImage: f.symbol)
                    .font(.footnote)
                    .foregroundStyle(Color.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Explicit score status: never leaves the user guessing why there is (or is not) a number.
struct StatusBadge: View {
    let recovery: Recovery

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(recovery.status.label, systemImage: recovery.status.hasScore ? "checkmark.seal" : "exclamationmark.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(recovery.status.color)
            if recovery.status != .scored {
                Text(recovery.statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
