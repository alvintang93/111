import SwiftUI
import MarginCore

extension RecoveryBand {
    var color: Color {
        switch self {
        case .primed: return .green
        case .steady: return .yellow
        case .depleted: return .red
        case .unknown: return .gray
        }
    }
}

extension Directive {
    var title: String {
        switch self {
        case .push: return "PUSH"
        case .maintain: return "MAINTAIN"
        case .recover: return "RECOVER"
        case .rest: return "REST"
        case .calibrating: return "CALIBRATING"
        case .noData: return "NO DATA"
        case .pending: return "PENDING"
        }
    }

    var color: Color {
        switch self {
        case .push: return .green
        case .maintain: return .yellow
        case .recover: return .orange
        case .rest: return .red
        case .calibrating, .noData, .pending: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .push: return "arrow.up.right"
        case .maintain: return "equal"
        case .recover: return "arrow.down.right"
        case .rest: return "bed.double.fill"
        case .calibrating: return "hourglass"
        case .noData: return "questionmark"
        case .pending: return "moon.zzz"
        }
    }
}

extension Confidence {
    var label: String {
        switch self {
        case .calibrating: return "Calibrating"
        case .noData: return "No overnight data"
        case .low: return "Low confidence"
        case .medium: return "Medium confidence"
        case .high: return "High confidence"
        }
    }
}

extension ComponentKind {
    var title: String {
        switch self {
        case .hrv: return "HRV"
        case .restingHR: return "Sleeping HR"
        case .sleep: return "Sleep vs need"
        case .respiratoryRate: return "Respiration"
        case .wristTemperature: return "Wrist temp"
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .hrv: return String(format: "%.0f ms", v)
        case .restingHR: return String(format: "%.0f bpm", v)
        case .sleep: return String(format: "%.0f%%", v)
        case .respiratoryRate: return String(format: "%.1f /min", v)
        case .wristTemperature: return String(format: "%.2f °C", v)
        }
    }
}

extension Flag {
    var title: String {
        switch self {
        case .elevatedVitals: return "Overnight vitals above usual"
        case .hrvTrendLow: return "HRV trend low"
        case .loadSpike: return "Load spike"
        case .sleepDebt: return "Sleep debt"
        }
    }

    var symbol: String {
        switch self {
        case .elevatedVitals: return "thermometer.medium"
        case .hrvTrendLow: return "waveform.path.ecg"
        case .loadSpike: return "chart.line.uptrend.xyaxis"
        case .sleepDebt: return "moon.zzz"
        }
    }
}

enum Fmt {
    static func load(_ v: Double?) -> String {
        v.map { String(format: "%.0f", $0) } ?? "–"
    }

    static func hours(_ h: Double) -> String {
        let totalMinutes = Int((h * 60).rounded())
        return "\(totalMinutes / 60)h \(String(format: "%02d", totalMinutes % 60))m"
    }

    static func ratio(_ v: Double?) -> String {
        v.map { String(format: "%.2f", $0) } ?? "–"
    }

    static func signed(_ v: Double?, digits: Int = 1) -> String {
        v.map { String(format: "%+.\(digits)f", $0) } ?? "–"
    }
}

extension ScoreStatus {
    var label: String {
        switch self {
        case .nightInProgress: return "Night in progress"
        case .hrvUnavailable: return "HRV unavailable"
        case .calibrating: return "Calibrating"
        case .noOvernightData: return "No overnight data"
        case .degraded: return "Partial data"
        case .provisional: return "Provisional scale"
        case .scored: return "Scored"
        }
    }

    var color: Color {
        switch self {
        case .scored: return .green
        case .provisional, .degraded: return .yellow
        case .nightInProgress, .calibrating: return .gray
        case .hrvUnavailable, .noOvernightData: return .orange
        }
    }
}

extension DailyBrief {
    /// A brief from a previous day must never be displayed as today's.
    func isCurrent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        day == Day(now, calendar: calendar)
    }
}

extension DashboardTile.Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        case .neutral: return .primary
        }
    }
}

extension StatusKind {
    var title: String {
        switch self {
        case .unwell: return "Unwell"
        case .sore: return "Sore"
        case .travel: return "Travel"
        }
    }

    var symbol: String {
        switch self {
        case .unwell: return "thermometer.medium"
        case .sore: return "bandage"
        case .travel: return "airplane"
        }
    }
}

extension StressBand {
    var title: String {
        switch self {
        case .rest: return "Rest"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var color: Color {
        switch self {
        case .rest: return .blue
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

extension TimelineItem.Kind {
    var symbol: String {
        switch self {
        case .sleep: return "moon.fill"
        case .wake: return "sun.max.fill"
        case .workout: return "figure.run"
        case .caffeine: return "cup.and.saucer.fill"
        case .water: return "drop.fill"
        case .journal: return "book.closed"
        case .status: return "flag.fill"
        }
    }

    var color: Color {
        switch self {
        case .sleep: return .indigo
        case .wake: return .yellow
        case .workout: return .orange
        case .caffeine: return .brown
        case .water: return .cyan
        case .journal: return .green
        case .status: return .pink
        }
    }
}

extension EnergySummary.StartSource {
    var explanation: String {
        switch self {
        case .recoveryAndSleep: return "Started from 65% recovery score and 35% sleep score."
        case .recovery: return "Started from the recovery score (no sleep score)."
        case .sleep: return "Started from the sleep score only, while recovery is unavailable."
        }
    }
}
