import Foundation
import MarginCore

enum PersistenceError: Error, CustomStringConvertible {
    case encode(String)
    case write(String)

    var description: String {
        switch self {
        case .encode(let m): return "encode failed: \(m)"
        case .write(let m): return "write failed: \(m)"
        }
    }
}

private func appSupportURL(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent(name)
}

private func writeAtomically(_ data: Data, to url: URL) throws {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    } catch {
        throw PersistenceError.write(error.localizedDescription)
    }
}

/// On-device cache of per-day aggregates. Every outcome is reported to the
/// caller for logging; nothing fails silently.
final class RecordStore {
    static let retentionDays = 400

    enum LoadOutcome {
        case loaded(count: Int, savedAt: Date)
        case empty
        case discarded(reason: String)
    }

    private let url = appSupportURL("day-records.json")

    func load() -> ([Day: DayRecord], LoadOutcome) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], .empty) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return ([:], .discarded(reason: "read failed: \(error.localizedDescription)"))
        }
        switch RecordCacheFile.decode(data) {
        case .ok(let records, let savedAt):
            let map = Dictionary(records.map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
            return (map, .loaded(count: map.count, savedAt: savedAt))
        case .schemaMismatch(let found, let expected):
            return ([:], .discarded(reason: "schema \(found) != \(expected); full rebuild from Health"))
        case .corrupt(let why):
            return ([:], .discarded(reason: "corrupt cache (\(why)); full rebuild from Health"))
        }
    }

    func save(_ records: [Day: DayRecord], at time: Date) throws {
        let file = RecordCacheFile(records: records, savedAt: time, retentionDays: Self.retentionDays)
        let data: Data
        do {
            data = try file.encoded()
        } catch {
            throw PersistenceError.encode(String(describing: error))
        }
        try writeAtomically(data, to: url)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Small Codable state files (event log, decision log).
final class JSONFileStore<T: Codable> {
    private let url: URL

    init(fileName: String) {
        url = appSupportURL(fileName)
    }

    enum LoadOutcome {
        case loaded(T)
        case empty
        case discarded(reason: String)
    }

    func load() -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .discarded(reason: String(describing: error))
        }
    }

    func save(_ value: T) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw PersistenceError.encode(String(describing: error))
        }
        try writeAtomically(data, to: url)
    }
}

/// Settings, journal and bookkeeping in standard UserDefaults.
final class Preferences {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let settings = "settings.v1"
        static let journal = "journal.v1"
        static let lastVitalsAlert = "lastElevatedVitalsAlertDay"
        static let runtime = "runtimeStatus.v1"
        static let lifestyle = "lifestyle.v1"
        static let statusPeriods = "statusPeriods.v1"
        static let lastMorningSummary = "checkIn.lastMorningSummaryDay"
        static let lastWeeklyReview = "checkIn.lastWeeklyReviewDay"
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

    func loadLifestyle() -> LifestyleSettings {
        guard let data = defaults.data(forKey: Key.lifestyle),
              let s = try? JSONDecoder().decode(LifestyleSettings.self, from: data) else { return LifestyleSettings() }
        return s
    }

    func saveLifestyle(_ s: LifestyleSettings) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Key.lifestyle) }
    }

    func loadStatusPeriods() -> [StatusPeriod] {
        guard let data = defaults.data(forKey: Key.statusPeriods),
              let s = try? JSONDecoder().decode([StatusPeriod].self, from: data) else { return [] }
        return s
    }

    func saveStatusPeriods(_ s: [StatusPeriod]) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Key.statusPeriods) }
    }

    var lastMorningSummaryDay: String? {
        get { defaults.string(forKey: Key.lastMorningSummary) }
        set { defaults.set(newValue, forKey: Key.lastMorningSummary) }
    }

    var lastWeeklyReviewDay: String? {
        get { defaults.string(forKey: Key.lastWeeklyReview) }
        set { defaults.set(newValue, forKey: Key.lastWeeklyReview) }
    }

    var lastVitalsAlertDay: String? {
        get { defaults.string(forKey: Key.lastVitalsAlert) }
        set { defaults.set(newValue, forKey: Key.lastVitalsAlert) }
    }

    func loadRuntime() -> AppRuntimeStatus {
        guard let data = defaults.data(forKey: Key.runtime),
              let s = try? JSONDecoder().decode(AppRuntimeStatus.self, from: data) else { return AppRuntimeStatus() }
        return s
    }

    func saveRuntime(_ s: AppRuntimeStatus) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Key.runtime) }
    }
}
