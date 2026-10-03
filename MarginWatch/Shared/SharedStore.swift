import Foundation
import MarginCore

/// Hand-off between the app (writer of the brief) and the complications
/// (writer of their heartbeat) via the App Group.
enum SharedStore {
    private static let briefKey = "brief.v2"
    private static let heartbeatKey = "widgetHeartbeat.v1"

    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "MarginAppGroupID") as? String
    }

    /// False when the App Group entitlement is missing or mismatched. The
    /// complication then cannot see the brief and would show "Open the app"
    /// forever; diagnostics surface this instead of failing silently.
    static var groupAvailable: Bool {
        guard let id = groupID, !id.isEmpty else { return false }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
    }

    private static var defaults: UserDefaults {
        groupID.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    enum LoadResult {
        case none
        case loaded(DailyBrief)
        case undecodable(String)
    }

    @discardableResult
    static func saveBrief(_ brief: DailyBrief) -> Error? {
        do {
            defaults.set(try JSONEncoder().encode(brief), forKey: briefKey)
            return nil
        } catch {
            return error
        }
    }

    static func loadBriefResult() -> LoadResult {
        guard let data = defaults.data(forKey: briefKey) else { return .none }
        do {
            return .loaded(try JSONDecoder().decode(DailyBrief.self, from: data))
        } catch {
            return .undecodable(String(String(describing: error).prefix(160)))
        }
    }

    static func loadBrief() -> DailyBrief? {
        if case .loaded(let b) = loadBriefResult() { return b }
        return nil
    }

    static func saveHeartbeat(_ h: WidgetHeartbeat) {
        if let data = try? JSONEncoder().encode(h) { defaults.set(data, forKey: heartbeatKey) }
    }

    static func loadHeartbeat() -> WidgetHeartbeat? {
        guard let data = defaults.data(forKey: heartbeatKey) else { return nil }
        return try? JSONDecoder().decode(WidgetHeartbeat.self, from: data)
    }
}
