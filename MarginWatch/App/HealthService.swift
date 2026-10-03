import Foundation
import HealthKit
import MarginCore

/// Thin HealthKit adapter: fetches raw samples and converts them into
/// MarginCore input types. All aggregation logic lives in MarginCore.
final class HealthService {
    let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static func quantity(_ id: HKQuantityTypeIdentifier) -> HKQuantityType {
        HKObjectType.quantityType(forIdentifier: id)!
    }

    private static let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    /// Every type Margin reads. Adding a type here makes the request status
    /// `.shouldRequest` again, so existing installs are re-prompted.
    var readTypes: Set<HKObjectType> {
        [
            Self.quantity(.heartRate),
            Self.quantity(.heartRateVariabilitySDNN),
            Self.quantity(.restingHeartRate),
            Self.quantity(.respiratoryRate),
            Self.quantity(.appleSleepingWristTemperature),
            Self.sleepType,
            HKObjectType.workoutType(),
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
        ]
    }

    /// Whether the permission sheet still needs to be shown. HealthKit never
    /// reveals whether *read* access was granted: a denied type simply returns
    /// no samples. Diagnostics therefore report data actually seen per type.
    func requestStatus() async -> HKAuthorizationRequestStatus {
        await withCheckedContinuation { cont in
            store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, _ in
                cont.resume(returning: status)
            }
        }
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    // MARK: - Characteristics

    func age(now: Date = Date()) -> Int? {
        guard let components = try? store.dateOfBirthComponents(),
              let birth = Calendar.current.date(from: components) else { return nil }
        return Calendar.current.dateComponents([.year], from: birth, to: now).year
    }

    func sex() -> Sex? {
        guard let value = try? store.biologicalSex().biologicalSex else { return nil }
        switch value {
        case .female: return .female
        case .male: return .male
        default: return nil
        }
    }

    // MARK: - Samples

    private func quantitySamples(_ id: HKQuantityTypeIdentifier, in interval: DateInterval) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: Self.quantity(id), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store)
    }

    private func values(_ id: HKQuantityTypeIdentifier, unit: HKUnit, in interval: DateInterval) async throws -> [TimedValue] {
        try await quantitySamples(id, in: interval).map {
            TimedValue(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
        }
    }

    func heartRate(in interval: DateInterval) async throws -> [HRSample] {
        try await quantitySamples(.heartRate, in: interval).map {
            HRSample(date: $0.startDate, bpm: $0.quantity.doubleValue(for: Self.bpm))
        }
    }

    func hrv(in interval: DateInterval) async throws -> [TimedValue] {
        try await values(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), in: interval)
    }

    func restingHR(in interval: DateInterval) async throws -> [TimedValue] {
        try await values(.restingHeartRate, unit: Self.bpm, in: interval)
    }

    func respiratoryRate(in interval: DateInterval) async throws -> [TimedValue] {
        try await values(.respiratoryRate, unit: Self.bpm, in: interval)
    }

    func wristTemperature(in interval: DateInterval) async throws -> [TimedValue] {
        try await values(.appleSleepingWristTemperature, unit: .degreeCelsius(), in: interval)
    }

    func workouts(in interval: DateInterval) async throws -> [WorkoutSample] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store).map {
            WorkoutSample(start: $0.startDate, end: $0.endDate, activityType: $0.workoutActivityType.rawValue)
        }
    }

    /// Returns segments plus the number of samples with an unrecognised sleep value (skipped, and logged).
    func sleep(in interval: DateInterval) async throws -> (segments: [SleepSegment], unknownValues: Int) {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: Self.sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        var unknown = 0
        let segments: [SleepSegment] = samples.compactMap { sample in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else {
                unknown += 1
                return nil
            }
            let stage: SleepStage
            switch value {
            case .inBed: stage = .inBed
            case .awake: stage = .awake
            case .asleepCore: stage = .core
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            case .asleepUnspecified: stage = .asleepUnspecified
            @unknown default:
                unknown += 1
                return nil
            }
            // Apple Watch sources win over iPhone or third-party sleep data.
            let isWatch = sample.sourceRevision.productType?.hasPrefix("Watch") == true
            return SleepSegment(start: sample.startDate, end: sample.endDate, stage: stage,
                                sourcePriority: isWatch ? 2 : 1)
        }
        return (segments, unknown)
    }
}

extension HKAuthorizationRequestStatus {
    var label: String {
        switch self {
        case .shouldRequest: return "shouldRequest"
        case .unnecessary: return "unnecessary (prompt answered)"
        case .unknown: return "unknown"
        @unknown default: return "unrecognised"
        }
    }
}
