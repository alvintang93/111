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
        }
    }

    var color: Color {
        switch self {
        case .push: return .green
        case .maintain: return .yellow
        case .recover: return .orange
        case .rest: return .red
        case .calibrating, .noData: return .gray
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
        case .illnessWatch: return "Illness watch"
        case .hrvTrendLow: return "HRV trend low"
        case .loadSpike: return "Load spike"
        case .sleepDebt: return "Sleep debt"
        }
    }

    var symbol: String {
        switch self {
        case .illnessWatch: return "thermometer.medium"
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

extension DailyBrief {
    /// A brief from a previous day must never be displayed as today's.
    func isCurrent(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        day == Day(now, calendar: calendar)
    }
}
