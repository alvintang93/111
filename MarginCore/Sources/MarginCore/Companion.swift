import Foundation

// MARK: - Watch → iPhone payload

/// Everything the iPhone app shows, sent by the watch after each rescore.
/// The watch stays the only place scores are computed.
public struct PhonePayload: Codable, Sendable, Equatable {
    public static let version = 1

    public var version: Int
    public var engineVersion: String
    public var sentAt: Date
    public var brief: DailyBrief
    public var strength: StrengthLog?
    /// Journal by day (`yyyy-MM-dd` → tags).
    public var journal: [String: [String]]
    public var lifestyle: LifestyleSettings
    public var routines: RoutineLibrary?
    public var activityLog: ActivityLog?

    public init(sentAt: Date, brief: DailyBrief, strength: StrengthLog?, journal: [Day: Set<String>],
                lifestyle: LifestyleSettings, routines: RoutineLibrary? = nil, activityLog: ActivityLog? = nil) {
        self.version = Self.version
        self.engineVersion = MarginCoreInfo.engineVersion
        self.sentAt = sentAt
        self.brief = brief
        self.strength = strength
        self.journal = Dictionary(uniqueKeysWithValues: journal.map { ($0.key.description, $0.value.sorted()) })
        self.lifestyle = lifestyle
        self.routines = routines
        self.activityLog = activityLog
    }

    public enum DecodeResult: Equatable {
        case ok(PhonePayload)
        case newerVersion(Int)
        case corrupt(String)
    }

    public static func decode(_ data: Data) -> DecodeResult {
        struct Header: Decodable { var version: Int }
        guard let h = try? JSONDecoder().decode(Header.self, from: data) else { return .corrupt("no header") }
        guard h.version <= version else { return .newerVersion(h.version) }
        do {
            return .ok(try JSONDecoder().decode(PhonePayload.self, from: data))
        } catch {
            return .corrupt(String(String(describing: error).prefix(160)))
        }
    }
}

// MARK: - Lab results (entered on the iPhone)

/// Common markers with their usual report unit. Margin does not supply
/// reference ranges: you enter the range printed on your own report.
public enum LabMarker: String, Codable, Sendable, CaseIterable {
    case ldl, hdl, totalCholesterol, triglycerides, apoB, hba1c, fastingGlucose, hsCRP
    case ferritin, vitaminD, testosterone, tsh, creatinine, egfr, hemoglobin, custom

    public var title: String {
        switch self {
        case .ldl: return "LDL cholesterol"
        case .hdl: return "HDL cholesterol"
        case .totalCholesterol: return "Total cholesterol"
        case .triglycerides: return "Triglycerides"
        case .apoB: return "ApoB"
        case .hba1c: return "HbA1c"
        case .fastingGlucose: return "Fasting glucose"
        case .hsCRP: return "hs-CRP"
        case .ferritin: return "Ferritin"
        case .vitaminD: return "Vitamin D (25-OH)"
        case .testosterone: return "Testosterone"
        case .tsh: return "TSH"
        case .creatinine: return "Creatinine"
        case .egfr: return "eGFR"
        case .hemoglobin: return "Hemoglobin"
        case .custom: return "Other"
        }
    }

    public var defaultUnit: String {
        switch self {
        case .ldl, .hdl, .totalCholesterol, .triglycerides, .apoB, .fastingGlucose: return "mg/dL"
        case .hba1c: return "%"
        case .hsCRP: return "mg/L"
        case .ferritin: return "ng/mL"
        case .vitaminD: return "ng/mL"
        case .testosterone: return "ng/dL"
        case .tsh: return "mIU/L"
        case .creatinine: return "mg/dL"
        case .egfr: return "mL/min/1.73m²"
        case .hemoglobin: return "g/dL"
        case .custom: return ""
        }
    }
}

public struct LabResult: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var marker: LabMarker
    /// Display name; for `.custom`, the name you typed.
    public var name: String
    public var value: Double
    public var unit: String
    public var date: Date
    /// Reference range from your lab report, if entered.
    public var referenceLow: Double?
    public var referenceHigh: Double?

    public init(id: UUID = UUID(), marker: LabMarker, name: String? = nil, value: Double, unit: String? = nil, date: Date,
                referenceLow: Double? = nil, referenceHigh: Double? = nil) {
        self.id = id
        self.marker = marker
        self.name = name ?? marker.title
        self.value = value
        self.unit = unit ?? marker.defaultUnit
        self.date = date
        self.referenceLow = referenceLow
        self.referenceHigh = referenceHigh
    }

    /// Nil when no reference range was entered.
    public var withinReference: Bool? {
        guard referenceLow != nil || referenceHigh != nil else { return nil }
        return value >= (referenceLow ?? -.infinity) && value <= (referenceHigh ?? .infinity)
    }

    /// Results of the same marker share this key (custom markers by name and unit).
    public var seriesKey: String {
        marker == .custom ? "custom:\(name.lowercased()):\(unit.lowercased())" : "\(marker.rawValue):\(unit.lowercased())"
    }
}

public struct LabSeries: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var name: String
    public var unit: String
    public var results: [LabResult]
    public var id: String { key }

    public var latest: LabResult { results.last! }
    public var previous: LabResult? { results.count >= 2 ? results[results.count - 2] : nil }
    public var change: Double? { previous.map { latest.value - $0.value } }

    public static func group(_ results: [LabResult]) -> [LabSeries] {
        var byKey: [String: [LabResult]] = [:]
        for r in results { byKey[r.seriesKey, default: []].append(r) }
        return byKey.map { k, rs in
            let sorted = rs.sorted { $0.date < $1.date }
            return LabSeries(key: k, name: sorted.last!.name, unit: sorted.last!.unit, results: sorted)
        }
        .sorted { ($0.latest.date, $0.name) > ($1.latest.date, $1.name) }
    }
}
