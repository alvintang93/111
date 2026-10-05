import Foundation
import HealthKit
import MarginCore
import WatchKit

/// Runs a live strength workout (HKWorkoutSession) so heart rate is sampled
/// densely and the session lands in Health and the Activity rings. Sets are
/// logged by Margin; the workout itself is saved to Health when it ends.
@MainActor
final class StrengthWorkoutManager: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var heartRate: Double?
    @Published private(set) var activeEnergyKcal: Double?
    @Published private(set) var startDate: Date?
    @Published private(set) var restEndsAt: Date?

    private let store: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var restTimer: Timer?

    init(store: HKHealthStore) {
        self.store = store
    }

    /// The HealthKit activity type of the running session.
    @Published private(set) var activityType: HKWorkoutActivityType = .traditionalStrengthTraining

    /// Starts a live workout session of any HealthKit activity type (strength by default).
    func start(_ type: HKWorkoutActivityType = .traditionalStrengthTraining, indoor: Bool = true) async throws {
        guard !isRunning else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = type
        config.locationType = indoor ? .indoor : .outdoor
        activityType = type
        let s = try HKWorkoutSession(healthStore: store, configuration: config)
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
        s.delegate = self
        b.delegate = self
        let now = Date()
        s.startActivity(with: now)
        try await b.beginCollection(at: now)
        session = s
        builder = b
        startDate = now
        isRunning = true
        heartRate = nil
        activeEnergyKcal = nil
    }

    /// Ends the session. When `save` is false the workout is discarded and nothing is written.
    func end(save: Bool) async throws -> HKWorkout? {
        guard let s = session, let b = builder else { return nil }
        cancelRest()
        let now = Date()
        s.end()
        defer {
            session = nil
            builder = nil
            isRunning = false
            startDate = nil
        }
        try await b.endCollection(at: now)
        guard save else {
            b.discardWorkout()
            return nil
        }
        return try await b.finishWorkout()
    }

    // MARK: Rest timer

    func startRest(seconds: Int) {
        cancelRest()
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restEndsAt = end
        restTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                WKInterfaceDevice.current().play(.stop)
                self?.restEndsAt = nil
            }
        }
    }

    func cancelRest() {
        restTimer?.invalidate()
        restTimer = nil
        restEndsAt = nil
    }

    fileprivate func apply(heartRate hr: Double?, energy: Double?) {
        if let hr { heartRate = hr }
        if let energy { activeEnergyKcal = energy }
    }
}

extension StrengthWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            AppModel.shared.log(.lifecycle, .error, "strength workout session failed: \(error.localizedDescription)")
        }
    }
}

extension StrengthWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hr = collectedTypes.contains(HKQuantityType(.heartRate))
            ? workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity()?.doubleValue(for: bpm) : nil
        let kcal = collectedTypes.contains(HKQuantityType(.activeEnergyBurned))
            ? workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) : nil
        Task { @MainActor in self.apply(heartRate: hr, energy: kcal) }
    }
}
