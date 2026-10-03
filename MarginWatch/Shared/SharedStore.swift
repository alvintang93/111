import Foundation
import MarginCore

/// Hand-off between the app (writer) and the complications (reader) via the App Group.
enum SharedStore {
    private static let briefKey = "brief.v1"

    static var groupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "MarginAppGroupID") as? String
    }

    private static var defaults: UserDefaults {
        groupID.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    static func saveBrief(_ brief: DailyBrief) {
        guard let data = try? JSONEncoder().encode(brief) else { return }
        defaults.set(data, forKey: briefKey)
    }

    static func loadBrief() -> DailyBrief? {
        guard let data = defaults.data(forKey: briefKey) else { return nil }
        return try? JSONDecoder().decode(DailyBrief.self, from: data)
    }
}
