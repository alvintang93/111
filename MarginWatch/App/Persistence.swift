import Foundation
import MarginCore

/// On-device cache of per-day aggregates so HealthKit is only re-queried for
/// today, yesterday and days never seen before.
final class RecordStore {
    private struct File: Codable {
        var schema: Int
        var records: [DayRecord]
    }

    static let retentionDays = 400

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("day-records.json")
    }()

    func load() -> [Day: DayRecord] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.schema == DayRecord.schemaVersion else { return [:] }
        return Dictionary(file.records.map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
    }

    func save(_ records: [Day: DayRecord]) {
        let kept = records.values.sorted { $0.day < $1.day }.suffix(Self.retentionDays)
        guard let data = try? JSONEncoder().encode(File(schema: DayRecord.schemaVersion, records: Array(kept))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Settings, journal and bookkeeping in standard UserDefaults.
final class Preferences {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let settings = "settings.v1"
        static let journal = "journal.v1"
        static let requestedAuth = "requestedHealthAuth"
        static let lastIllnessAlert = "lastIllnessAlertDay"
    }

    func loadSettings() -> UserSettings {
        guard let data = defaults.data(forKey: Key.settings),
              let s = try? JSONDecoder().decode(UserSettings.self, from: data) else { return UserSettings() }
        return s
    }

    func saveSettings(_ s: UserSettings) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Key.settings) }
    }

    func loadJournal() -> [Day: Set<String>] {
        guard let raw = defaults.dictionary(forKey: Key.journal) as? [String: [String]] else { return [:] }
        var out: [Day: Set<String>] = [:]
        for (k, v) in raw {
            if let d = Day(string: k) { out[d] = Set(v) }
        }
        return out
    }

    func saveJournal(_ journal: [Day: Set<String>]) {
        var raw: [String: [String]] = [:]
        for (d, tags) in journal { raw[d.description] = tags.sorted() }
        defaults.set(raw, forKey: Key.journal)
    }

    var hasRequestedAuthorization: Bool {
        get { defaults.bool(forKey: Key.requestedAuth) }
        set { defaults.set(newValue, forKey: Key.requestedAuth) }
    }

    var lastIllnessAlertDay: String? {
        get { defaults.string(forKey: Key.lastIllnessAlert) }
        set { defaults.set(newValue, forKey: Key.lastIllnessAlert) }
    }
}
