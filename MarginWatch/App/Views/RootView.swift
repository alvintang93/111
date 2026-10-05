import SwiftUI
import MarginCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            TabView {
                TodayView()
                EnergyView()
                DriversView()
                SleepView()
                LoadView()
                TrendsView()
                MoreView()
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

/// Shown on every page when no current brief exists.
struct EmptyState: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if model.isRefreshing {
                if let p = model.progress {
                    ProgressView(value: p)
                    Text("Reading Health history… \(Int(p * 100))%").font(.footnote)
                } else {
                    ProgressView()
                }
            } else {
                Image(systemName: "heart.text.square").font(.title2)
                Text(model.status ?? "No data yet. Wear the watch overnight, then refresh.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Double tap (watchOS 11+, Series 9 / Ultra 2 and later) triggers the primary action.
struct PrimaryDoubleTap: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}

struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(tint).monospacedDigit()
        }
        .font(.footnote)
    }
}
