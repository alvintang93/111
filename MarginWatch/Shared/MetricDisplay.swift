import SwiftUI
import MarginCore

// Formatting for health metric reports, shared by the watch and iPhone apps.

extension MetricDataState {
    var label: String {
        switch self {
        case .available: return "Up to date"
        case .stale: return "Stale"
        case .insufficientHistory: return "Building baseline"
        case .noMeasurement: return "No readings"
        case .notAuthorized: return "Needs permission"
        case .readFailed: return "Read failed"
        }
    }

    var color: Color {
        switch self {
        case .available: return .green
        case .stale, .insufficientHistory: return .yellow
        case .noMeasurement, .notAuthorized: return .gray
        case .readFailed: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .available: return "checkmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .insufficientHistory: return "hourglass"
        case .noMeasurement: return "circle.dashed"
        case .notAuthorized: return "lock"
        case .readFailed: return "exclamationmark.triangle"
        }
    }
}

extension HealthMetricKind {
    var symbol: String {
        switch self {
        case .hrv: return "waveform.path.ecg"
        case .sleepingHR, .restingHR: return "heart"
        case .respiratoryRate: return "lungs"
        case .wristTemperature: return "thermometer.medium"
        case .spo2: return "drop.degreesign"
        case .sleep: return "bed.double"
        case .vo2Max: return "figure.run"
        case .bodyMass, .bodyFat, .leanMass: return "scalemass"
        case .hrRecovery: return "arrow.down.heart"
        case .load: return "flame"
        }
    }

    func format(_ v: Double?) -> String {
        guard let v else { return "–" }
        if self == .sleep {
            let m = Int((v * 60).rounded())
            return "\(m / 60)h \(String(format: "%02d", m % 60))m"
        }
        return String(format: "%.\(digits)f", v)
    }

    func formatSigned(_ v: Double?) -> String {
        guard let v else { return "–" }
        if self == .sleep { return String(format: "%+.0f min", v * 60) }
        return String(format: "%+.\(max(digits, 1))f", v)
    }
}

extension MetricReport {
    /// One-line change from baseline (or from the previous reading for sporadic metrics).
    var changeLine: String? {
        if let d = deltaFromBaseline, let b = baseline {
            if let p = deltaPercent {
                return String(format: "%+.0f%% vs usual %@ %@", p, kind.format(b.center), kind.unit)
            }
            return "\(kind.formatSigned(d)) \(kind.unit) vs usual \(kind.format(b.center))"
        }
        if let c = current, let p = previous, !kind.hasRollingBaseline {
            return "\(kind.formatSigned(c.value - p.value)) \(kind.unit) since \(p.date.formatted(date: .abbreviated, time: .omitted))"
        }
        return nil
    }

    /// Colour of the change: green when favourable for this metric, orange when unfavourable and notable.
    var changeColor: Color {
        guard let better = kind.higherIsBetter else { return .secondary }
        let signed: Double?
        if let z { signed = z } else if let c = current, let p = previous { signed = c.value - p.value } else { signed = nil }
        guard let s = signed, abs(s) >= (z != nil ? 1 : 0.0001) else { return .secondary }
        return (s > 0) == better ? .green : .orange
    }

    /// Notable for Today: at least 1 robust SD from baseline.
    var isNotable: Bool { (z.map { abs($0) >= 1 } ?? false) && current?.day != nil && state != .stale }
}
