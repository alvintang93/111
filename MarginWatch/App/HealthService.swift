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

    var readTypes: Set<HKObjectType> {
        [
            Self.quantity(.heartRate),
            Self.quantity(.heartRateVariabilitySDNN),
            Self.quantity(.restingHeartRate),
            Self.quantity(.respiratoryRate),
            Self.quantity(.appleSleepingWristTemperature),
            Self.sleepType,
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
        ]
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

    func sleep(in interval: DateInterval) async throws -> [SleepSegment] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: Self.sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        return samples.compactMap { sample in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
            let stage: SleepStage
            switch value {
            case .inBed: stage = .inBed
            case .awake: stage = .awake
            case .asleepCore: stage = .core
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            case .asleepUnspecified: stage = .asleepUnspecified
            @unknown default: return nil
            }
            // Apple Watch sources win over iPhone or third-party sleep data.
            let isWatch = sample.sourceRevision.productType?.hasPrefix("Watch") == true
            return SleepSegment(start: sample.startDate, end: sample.endDate, stage: stage,
                                sourcePriority: isWatch ? 2 : 1)
        }
    }
}
