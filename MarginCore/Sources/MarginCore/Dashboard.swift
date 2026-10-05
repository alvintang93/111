import Foundation

/// Metrics that can be pinned to the Today page or shown in a complication.
public enum DashboardMetric: String, Codable, Sendable, CaseIterable {
    case recovery, strain, energy, stress, sleep, hrv, sleepingHR, caffeine, water, hrRecovery

    public var title: String {
        switch self {
        case .recovery: return "Recovery"
        case .strain: return "Strain"
        case .energy: return "Energy"
        case .stress: return "Stress"
        case .sleep: return "Sleep"
        case .hrv: return "HRV"
        case .sleepingHR: return "Sleeping HR"
        case .caffeine: return "Caffeine"
        case .water: return "Water"
        case .hrRecovery: return "HR recovery"
        }
    }
}

/// What a tile or metric complication renders. Pure function of the brief, so
/// stale and missing states are tested here rather than in views.
public struct DashboardTile: Sendable, Equatable {
    public enum Tone: String, Sendable {
        case good, fair, poor, neutral
    }

    public var metric: DashboardMetric
    public var value: String
    public var caption: String
    /// 0...1 for gauges; nil when the metric has no natural maximum or no value.
    public var fraction: Double?
    public var tone: Tone
    public var available: Bool

    static func unavailable(_ m: DashboardMetric, _ caption: String) -> DashboardTile {
        DashboardTile(metric: m, value: "–", caption: caption, fraction: nil, tone: .neutral, available: false)
    }

    public static func make(_ metric: DashboardMetric, brief: DailyBrief?, now: Date,
                            calendar: Calendar) -> DashboardTile {
        guard let b = brief else { return unavailable(metric, "Open Margin") }
        guard b.day == Day(now, calendar: calendar) else { return unavailable(metric, "Open to update") }
        func band(_ v: Int, high: Int = 67, low: Int = 33) -> Tone {
            v >= high ? .good : (v <= low ? .poor : .fair)
        }
        switch metric {
        case .recovery:
            let r = b.recovery
            guard let s = r.score else {
                let c = r.calibration
                return unavailable(metric, r.status == .calibrating ? "Calibrating \(c.hrvNights)/\(c.hrvNightsRequired)" : "No score")
            }
            return DashboardTile(metric: metric, value: "\(s)", caption: "of 100", fraction: Double(s) / 100,
                                 tone: band(s, high: ModelParameters.standard.primedThreshold,
                                            low: ModelParameters.standard.depletedThreshold),
                                 available: true)
        case .strain:
            guard let st = b.strain, let s = st.score else { return unavailable(metric, "Wear the watch") }
            let caption = (st.targetLow != nil && st.targetHigh != nil)
                ? "target \(st.targetLow!)–\(st.targetHigh!)" : (st.reference == .provisional ? "provisional" : "of 100")
            return DashboardTile(metric: metric, value: "\(s)", caption: caption, fraction: Double(s) / 100,
                                 tone: .neutral, available: true)
        case .energy:
            guard let e = b.energy else { return unavailable(metric, "After you wake") }
            return DashboardTile(metric: metric, value: "\(e.current)", caption: "started \(e.start)",
                                 fraction: Double(e.current) / 100, tone: band(e.current), available: true)
        case .stress:
            guard let st = b.stress, let level = st.current ?? st.score else { return unavailable(metric, "Not enough rest data") }
            let tone: Tone
            switch StressBand(level: level) {
            case .rest, .low: tone = .good
            case .medium: tone = .fair
            case .high: tone = .poor
            }
            let caption = st.score.map { "\(StressBand(level: level).rawValue) · day \($0)" } ?? StressBand(level: level).rawValue
            return DashboardTile(metric: metric, value: "\(level)", caption: caption, fraction: Double(level) / 100,
                                 tone: tone, available: true)
        case .sleep:
            guard let s = b.sleep else { return unavailable(metric, "No sleep recorded") }
            return DashboardTile(metric: metric, value: "\(s.score)", caption: Self.hours(s.asleepHours),
                                 fraction: Double(s.score) / 100, tone: band(s.score, high: 80, low: 60), available: true)
        case .hrv:
            guard let c = b.recovery.components.first(where: { $0.kind == .hrv }) else {
                return unavailable(metric, "No HRV last night")
            }
            return DashboardTile(metric: metric, value: String(format: "%.0f", c.value),
                                 caption: c.baseline.map { String(format: "ms · base %.0f", $0) } ?? "ms",
                                 fraction: nil, tone: c.z >= 0 ? .good : (c.z <= -1 ? .poor : .fair), available: true)
        case .sleepingHR:
            guard let c = b.recovery.components.first(where: { $0.kind == .restingHR }) else {
                return unavailable(metric, "No sleeping HR")
            }
            return DashboardTile(metric: metric, value: String(format: "%.0f", c.value),
                                 caption: c.baseline.map { String(format: "bpm · base %.0f", $0) } ?? "bpm",
                                 fraction: nil, tone: c.z >= 0 ? .good : (c.z <= -1 ? .poor : .fair), available: true)
        case .caffeine:
            guard let i = b.intake else { return unavailable(metric, "Nothing logged") }
            let caption: String
            if let cut = i.cutoff {
                caption = cut > now ? "cut-off \(Self.clock(cut, calendar))" : "cut-off passed"
            } else {
                caption = "over limit at bed"
            }
            let tone: Tone = i.caffeineAtBedtimeMg >= i.limitMg ? .poor : (i.cutoff.map { $0 <= now } ?? true ? .fair : .good)
            return DashboardTile(metric: metric, value: String(format: "%.0f", i.caffeineNowMg), caption: "mg · " + caption,
                                 fraction: nil, tone: tone, available: true)
        case .water:
            guard let i = b.intake, i.waterTargetMl > 0 else { return unavailable(metric, "Nothing logged") }
            let f = min(i.waterTodayMl / i.waterTargetMl, 1)
            return DashboardTile(metric: metric, value: String(format: "%.1f L", i.waterTodayMl / 1000),
                                 caption: String(format: "of %.1f L", i.waterTargetMl / 1000), fraction: f,
                                 tone: f >= 1 ? .good : .neutral, available: true)
        case .hrRecovery:
            guard let h = b.heartRateRecovery else { return unavailable(metric, "No recent workout") }
            guard let d = h.recent.last?.drop else { return unavailable(metric, "No post-workout HR") }
            let tone: Tone = h.typicalDrop.map { d >= $0 ? .good : (d < $0 - 5 ? .poor : .fair) } ?? .neutral
            return DashboardTile(metric: metric, value: String(format: "%.0f", d),
                                 caption: h.typicalDrop.map { String(format: "bpm · typical %.0f", $0) } ?? "bpm in 1 min",
                                 fraction: nil, tone: tone, available: true)
        }
    }

    static func hours(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    static func clock(_ d: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
