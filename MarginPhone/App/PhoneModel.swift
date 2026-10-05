import Foundation
import HealthKit
import MarginCore
import WatchConnectivity
import WidgetKit

/// iPhone state: the latest payload from the watch, lab results, meals logged
/// on the phone, and the watch link. Scores are never recomputed here.
@MainActor
final class PhoneModel: NSObject, ObservableObject {
    static let shared = PhoneModel()

    @Published private(set) var payload: PhonePayload?
    @Published private(set) var labs: [LabResult]
    @Published private(set) var watchReachable = false
    @Published private(set) var watchPaired = false
    @Published private(set) var lastReceivedAt: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var mealsToday: NutritionDay?
    @Published var pinned: [DashboardMetric] {
        didSet { save(pinned, key: Keys.pinned) }
    }

    let health = HKHealthStore()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pinned = "phone.pinned.v1"
        static let labs = "phone.labs.v1"
    }

    private static var payloadURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("payload.json")
    }

    private override init() {
        labs = (try? JSONDecoder().decode([LabResult].self, from: UserDefaults.standard.data(forKey: Keys.labs) ?? Data())) ?? []
        pinned = (try? JSONDecoder().decode([DashboardMetric].self, from: UserDefaults.standard.data(forKey: Keys.pinned) ?? Data()))
            ?? [.strain, .energy, .stress, .sleep, .hrv, .topLift]
        localRoutines = (try? JSONDecoder().decode(RoutineLibrary.self, from: UserDefaults.standard.data(forKey: "phone.routines.v1") ?? Data()))
        super.init()
        if let data = try? Data(contentsOf: Self.payloadURL), case .ok(let p) = PhonePayload.decode(data) {
            payload = p
            lastReceivedAt = p.sentAt
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    var brief: DailyBrief? { payload?.brief }
    var unit: WeightUnit { payload?.lifestyle.weightUnit ?? .kg }

    // MARK: Watch link

    /// Asks the watch for a fresh sync when it is reachable (app open on the watch).
    func requestRefresh() {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["request": "refresh"], replyHandler: nil) { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in self?.syncError = message }
        }
    }

    fileprivate func receive(_ data: Data) {
        switch PhonePayload.decode(data) {
        case .ok(let p):
            guard p.sentAt >= (payload?.sentAt ?? .distantPast) else { return }
            payload = p
            lastReceivedAt = p.sentAt
            syncError = nil
            try? FileManager.default.createDirectory(at: Self.payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.payloadURL, options: .atomic)
            SharedStore.saveBrief(p.brief)
            WidgetCenter.shared.reloadAllTimelines()
        case .newerVersion(let v):
            syncError = "The watch app is newer (payload v\(v)). Update Margin on this iPhone."
        case .corrupt(let why):
            syncError = "Couldn't read data from the watch (\(why))."
        }
    }

    fileprivate func updateLink(_ s: WCSession) {
        watchPaired = s.isPaired
        watchReachable = s.isReachable
    }

    // MARK: Routines (edited here, synced to the watch)

    /// Routines as last seen from the watch, plus edits made on this iPhone.
    @Published private(set) var localRoutines: RoutineLibrary?

    var routines: RoutineLibrary {
        let fromWatch = payload?.routines ?? RoutineLibrary()
        return localRoutines.map { $0.merged(with: fromWatch) } ?? fromWatch
    }

    func saveRoutine(_ r: Routine) {
        var lib = routines
        if lib.routine(r.id) == nil {
            var new = lib.create(name: r.name, items: r.items, at: Date())
            new.notes = r.notes
            lib.update(new, at: Date())
        } else {
            lib.update(r, at: Date())
        }
        push(lib)
    }

    func deleteRoutine(_ id: UUID) {
        var lib = routines
        lib.delete(id, at: Date())
        push(lib)
    }

    func duplicateRoutine(_ id: UUID) {
        var lib = routines
        lib.duplicate(id, at: Date())
        push(lib)
    }

    /// Queued for the watch (delivered when it is next reachable); merged there by newest edit.
    private func push(_ lib: RoutineLibrary) {
        localRoutines = lib
        if let data = try? JSONEncoder().encode(lib) {
            UserDefaults.standard.set(data, forKey: "phone.routines.v1")
            if WCSession.isSupported(), WCSession.default.activationState == .activated {
                WCSession.default.transferUserInfo(["routines": data])
            }
        }
    }

    // MARK: Labs

    func addLab(_ r: LabResult) {
        labs.append(r)
        save(labs, key: Keys.labs)
    }

    func deleteLab(_ id: UUID) {
        labs.removeAll { $0.id == id }
        save(labs, key: Keys.labs)
    }

    var labSeries: [LabSeries] { LabSeries.group(labs) }

    // MARK: Meals (written to Health)

    private static let mealTypes: [(HKQuantityTypeIdentifier, HKUnit)] = [
        (.dietaryEnergyConsumed, .kilocalorie()), (.dietaryProtein, .gram()),
        (.dietaryCarbohydrates, .gram()), (.dietaryFatTotal, .gram()),
    ]

    func logMeal(kcal: Double?, protein: Double?, carbs: Double?, fat: Double?, name: String, at date: Date = Date()) async throws {
        let types = Set(Self.mealTypes.map { HKQuantityType($0.0) })
        try await health.requestAuthorization(toShare: types, read: types)
        let values = [kcal, protein, carbs, fat]
        var samples: [HKQuantitySample] = []
        for ((id, unit), v) in zip(Self.mealTypes, values) {
            guard let v, v > 0 else { continue }
            samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: v),
                                            start: date, end: date, metadata: name.isEmpty ? nil : [HKMetadataKeyFoodType: name]))
        }
        guard !samples.isEmpty else { return }
        try await health.save(samples)
        await refreshMealsToday()
    }

    func refreshMealsToday() async {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        var day = NutritionDay(day: Day(Date(), calendar: cal))
        let keys: [WritableKeyPath<NutritionDay, Double?>] = [\.energyKcal, \.proteinG, \.carbsG, \.fatG]
        for ((id, unit), key) in zip(Self.mealTypes, keys) {
            let d = HKStatisticsQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: nil)),
                options: .cumulativeSum)
            day[keyPath: key] = (try? await d.result(for: health))?.sumQuantity()?.doubleValue(for: unit)
        }
        mealsToday = day
    }
}

extension PhoneModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.updateLink(.default) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching watches: activate again for the new one.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateLink(.default) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateLink(.default) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this method returns, so read it now.
        guard let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in self.receive(data) }
    }
}
