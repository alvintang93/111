import Foundation

/// A timestamped measurement (HealthKit quantity sample, already in display units).
public struct TimedValue: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let value: Double

    public init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }
}

/// Parameter-independent daily aggregates. Cached on device; all scores are
/// recomputed from these, so changing settings never requires a re-query.
public struct DayRecord: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let day: Day
    public var sleep: SleepNight?
    /// Mean of ln(SDNN ms) over the main sleep bout (or fallback overnight window).
    public var lnHRV: Double?
    public var hrvSampleCount: Int
    public var hrvDuringSleep: Bool
    /// 10th percentile of heart rate during the main sleep bout.
    public var sleepingHR: Double?
    /// Apple's daily resting heart rate for this calendar day.
    public var appleRestingHR: Double?
    public var respiratoryRate: Double?
    public var wristTemperature: Double?
    /// Time-at-heart-rate for the calendar day.
    public var activity: HeartRateHistogram

    public var coverageHours: Double { activity.totalSeconds / 3600 }

    public init(day: Day,
                sleep: SleepNight? = nil,
                lnHRV: Double? = nil,
                hrvSampleCount: Int = 0,
                hrvDuringSleep: Bool = false,
                sleepingHR: Double? = nil,
                appleRestingHR: Double? = nil,
                respiratoryRate: Double? = nil,
                wristTemperature: Double? = nil,
                activity: HeartRateHistogram = HeartRateHistogram()) {
        self.day = day
        self.sleep = sleep
        self.lnHRV = lnHRV
        self.hrvSampleCount = hrvSampleCount
        self.hrvDuringSleep = hrvDuringSleep
        self.sleepingHR = sleepingHR
        self.appleRestingHR = appleRestingHR
        self.respiratoryRate = respiratoryRate
        self.wristTemperature = wristTemperature
        self.activity = activity
    }
}

public struct RawDayInput: Sendable {
    public var sleep: [SleepSegment]
    /// SDNN in milliseconds.
    public var hrv: [TimedValue]
    public var heartRate: [HRSample]
    public var restingHR: [TimedValue]
    public var respiratoryRate: [TimedValue]
    /// Degrees Celsius.
    public var wristTemperature: [TimedValue]

    public init(sleep: [SleepSegment] = [], hrv: [TimedValue] = [], heartRate: [HRSample] = [],
                restingHR: [TimedValue] = [], respiratoryRate: [TimedValue] = [],
                wristTemperature: [TimedValue] = []) {
        self.sleep = sleep
        self.hrv = hrv
        self.heartRate = heartRate
        self.restingHR = restingHR
        self.respiratoryRate = respiratoryRate
        self.wristTemperature = wristTemperature
    }

    /// Union of all windows `DayRecordBuilder` reads for `day`. Fetch at least this range.
    public static func fetchInterval(for day: Day, calendar: Calendar) -> DateInterval {
        DateInterval(start: day.nightWindow(calendar: calendar).start,
                     end: day.calendarWindow(calendar: calendar).end)
    }
}

public enum DayRecordBuilder {
    /// Inputs may contain samples outside the day; each field filters to its own window.
    public static func build(day: Day, calendar: Calendar, input: RawDayInput,
                             params: ModelParameters = .standard) -> DayRecord {
        let nightWindow = day.nightWindow(calendar: calendar)
        let night = SleepAggregator.aggregate(segments: input.sleep, window: nightWindow,
                                              boutMergeGap: params.sleepBoutMergeGap)
        let overnight = night.map { DateInterval(start: $0.mainOnset, end: $0.mainWake) }
            ?? day.fallbackOvernightWindow(calendar: calendar)

        func inOvernight(_ d: Date) -> Bool { d >= overnight.start && d <= overnight.end }

        let hrvValues = input.hrv.filter { inOvernight($0.start) && $0.value > 0 }.map { log($0.value) }

        var sleepingHR: Double?
        if let n = night {
            let hrs = input.heartRate
                .filter { $0.date >= n.mainOnset && $0.date <= n.mainWake && $0.bpm > 0 }
                .map(\.bpm)
            if hrs.count >= params.minSleepHRSamples {
                sleepingHR = Stats.quantile(hrs, params.sleepingHRQuantile)
            }
        }

        let calWindow = day.calendarWindow(calendar: calendar)
        let rhr = input.restingHR
            .filter { $0.start >= calWindow.start && $0.start < calWindow.end && $0.value > 0 }
            .map(\.value)
        let rr = input.respiratoryRate.filter { inOvernight($0.start) && $0.value > 0 }.map(\.value)
        let temp = input.wristTemperature
            .filter { $0.end > nightWindow.start && $0.end <= nightWindow.end }
            .map(\.value)

        return DayRecord(
            day: day,
            sleep: night,
            lnHRV: Stats.mean(hrvValues),
            hrvSampleCount: hrvValues.count,
            hrvDuringSleep: night != nil && !hrvValues.isEmpty,
            sleepingHR: sleepingHR,
            appleRestingHR: Stats.mean(rhr),
            respiratoryRate: Stats.mean(rr),
            wristTemperature: Stats.mean(temp),
            activity: HeartRateHistogram.build(samples: input.heartRate, window: calWindow,
                                               maxGap: params.maxSampleGap)
        )
    }
}
