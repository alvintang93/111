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
            Self.quantity(.stepCount),
            Self.quantity(.heartRateRecoveryOneMinute),
            Self.quantity(.bodyMass),
            Self.quantity(.vo2Max),
            Self.quantity(.oxygenSaturation),
            Self.quantity(.bloodPressureSystolic),
            Self.quantity(.bloodPressureDiastolic),
            Self.quantity(.bodyFatPercentage),
            Self.quantity(.leanBodyMass),
            Self.quantity(.bloodGlucose),
            Self.quantity(.dietaryEnergyConsumed),
            Self.quantity(.dietaryProtein),
            Self.quantity(.dietaryCarbohydrates),
            Self.quantity(.dietaryFatTotal),
            Self.quantity(.distanceWalkingRunning),
            Self.quantity(.runningStrideLength),
            Self.quantity(.runningVerticalOscillation),
            Self.quantity(.runningGroundContactTime),
            Self.quantity(.runningPower),
            Self.quantity(.runningSpeed),
            HKObjectType.categoryType(forIdentifier: .menstrualFlow)!,
            Self.sleepType,
            HKObjectType.workoutType(),
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!,
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)!,
        ]
    }

    /// Written only by the strength builder's live workouts (the workout and the
    /// heart rate and energy the watch records during it).
    var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), Self.quantity(.heartRate), Self.quantity(.activeEnergyBurned)]
    }

    /// Whether the permission sheet still needs to be shown. HealthKit never
    /// reveals whether *read* access was granted: a denied type simply returns
    /// no samples. Diagnostics therefore report data actually seen per type.
    func requestStatus() async -> HKAuthorizationRequestStatus {
        await withCheckedContinuation { cont in
            store.getRequestStatusForAuthorization(toShare: shareTypes, read: readTypes) { status, _ in
                cont.resume(returning: status)
            }
        }
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
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
            TimedValue(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit),
                       source: $0.sourceRevision.source.name)
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

    /// Step samples as recorded (value = steps over the sample interval).
    func steps(in interval: DateInterval) async throws -> [TimedValue] {
        try await values(.stepCount, unit: .count(), in: interval)
    }

    /// Apple's one-minute heart-rate recovery after workouts (bpm drop).
    func heartRateRecovery(in interval: DateInterval) async throws -> [TimedValue] {
        try await values(.heartRateRecoveryOneMinute, unit: Self.bpm, in: interval)
    }

    /// Most recent body mass in kg, if any (fluid target only).
    func latestBodyMass() async throws -> Double? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: Self.quantity(.bodyMass))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try await descriptor.result(for: store).first?.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    // MARK: - Biomarkers (batch 2)

    /// Readings of one biomarker in display units (see `BiomarkerKind`).
    func biomarker(_ kind: BiomarkerKind, in interval: DateInterval) async throws -> [TimedValue] {
        switch kind {
        case .vo2Max: return try await values(.vo2Max, unit: HKUnit(from: "ml/kg*min"), in: interval)
        case .systolic: return try await values(.bloodPressureSystolic, unit: .millimeterOfMercury(), in: interval)
        case .diastolic: return try await values(.bloodPressureDiastolic, unit: .millimeterOfMercury(), in: interval)
        case .bodyFat:
            return try await values(.bodyFatPercentage, unit: .percent(), in: interval)
                .map { TimedValue(start: $0.start, end: $0.end, value: $0.value * 100) }
        case .leanMass: return try await values(.leanBodyMass, unit: .gramUnit(with: .kilo), in: interval)
        case .bodyMass: return try await values(.bodyMass, unit: .gramUnit(with: .kilo), in: interval)
        case .glucose: return try await values(.bloodGlucose, unit: HKUnit(from: "mg/dL"), in: interval)
        case .spo2:
            // HealthKit's percent unit yields a 0-1 fraction; anything else is rejected, not rescaled.
            return try await values(.oxygenSaturation, unit: .percent(), in: interval).compactMap { v in
                HealthUnits.percent(fromFraction: v.value).map { TimedValue(start: v.start, end: v.end, value: $0, source: v.source) }
            }
        }
    }

    /// Daily sums of logged energy and macronutrients (written to Health by other apps).
    func nutrition(days: Int, calendar: Calendar = .current) async throws -> [NutritionDay] {
        let end = calendar.startOfDay(for: Date()).addingTimeInterval(86400)
        let start = calendar.date(byAdding: .day, value: -days, to: end)!
        var out: [Day: NutritionDay] = [:]
        let kinds: [(HKQuantityTypeIdentifier, HKUnit, WritableKeyPath<NutritionDay, Double?>)] = [
            (.dietaryEnergyConsumed, .kilocalorie(), \.energyKcal),
            (.dietaryProtein, .gram(), \.proteinG),
            (.dietaryCarbohydrates, .gram(), \.carbsG),
            (.dietaryFatTotal, .gram(), \.fatG),
        ]
        for (id, unit, key) in kinds {
            let descriptor = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: Self.quantity(id),
                                           predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
                options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            let collection = try await descriptor.result(for: store)
            collection.enumerateStatistics(from: start, to: end) { stats, _ in
                guard let sum = stats.sumQuantity() else { return }
                let d = Day(stats.startDate, calendar: calendar)
                var n = out[d] ?? NutritionDay(day: d)
                n[keyPath: key] = sum.doubleValue(for: unit)
                out[d] = n
            }
        }
        return out.values.sorted { $0.day < $1.day }
    }

    /// Days with menstrual flow recorded (any level except "none").
    func menstrualFlow(in interval: DateInterval, calendar: Calendar = .current) async throws -> [FlowDay] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKObjectType.categoryType(forIdentifier: .menstrualFlow)!,
                                         predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        // Raw values: 1 unspecified, 2 light, 3 medium, 4 heavy, 5 none.
        return try await descriptor.result(for: store)
            .filter { (1...4).contains($0.value) }
            .map { FlowDay(day: Day($0.startDate, calendar: calendar), level: $0.value) }
    }

    /// Form metrics for one run, averaged by Health over the run.
    func runMetrics(start: Date, end: Date) async throws -> RunMetrics {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        func stat(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, sum: Bool) async throws -> Double? {
            let d = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: Self.quantity(id), predicate: predicate),
                                                options: sum ? .cumulativeSum : .discreteAverage)
            let s = try await d.result(for: store)
            return (sum ? s?.sumQuantity() : s?.averageQuantity())?.doubleValue(for: unit)
        }
        return RunMetrics(
            start: start, end: end,
            distanceKm: try await stat(.distanceWalkingRunning, .meterUnit(with: .kilo), sum: true),
            steps: try await stat(.stepCount, .count(), sum: true),
            strideLengthM: try await stat(.runningStrideLength, .meter(), sum: false),
            verticalOscillationCm: try await stat(.runningVerticalOscillation, .meterUnit(with: .centi), sum: false),
            groundContactMs: try await stat(.runningGroundContactTime, .secondUnit(with: .milli), sum: false),
            powerW: try await stat(.runningPower, .watt(), sum: false),
            speedMS: try await stat(.runningSpeed, HKUnit.meter().unitDivided(by: .second()), sum: false))
    }

    // MARK: - Writes (only what the person logs)

    /// Saves a workout the person entered after the fact. Returns its Health UUID.
    func saveWorkout(type: UInt, start: Date, end: Date, rpe: Int?) async throws -> UUID {
        let config = HKWorkoutConfiguration()
        config.activityType = HKWorkoutActivityType(rawValue: type) ?? .other
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)
        var metadata: [String: Any] = [HKMetadataKeyWasUserEntered: true]
        if let rpe { metadata["MarginRPE"] = rpe }
        try await builder.addMetadata(metadata)
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else {
            throw NSError(domain: "Margin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Health didn't return the saved workout."])
        }
        return workout.uuid
    }

    /// Deletes a workout Margin saved (HealthKit only allows deleting an app's own samples).
    func deleteWorkout(_ id: UUID) async throws {
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: id))], sortDescriptors: [])
        for w in try await descriptor.result(for: store) { try await store.delete(w) }
    }

    func workouts(in interval: DateInterval) async throws -> [WorkoutSample] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store).map {
            WorkoutSample(start: $0.startDate, end: $0.endDate, activityType: $0.workoutActivityType.rawValue,
                          healthID: $0.uuid, source: $0.sourceRevision.source.name)
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
