import Foundation
@testable import MarginCore

/// New York exercises DST transitions in every date-dependent test.
let testCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}()

func at(_ day: Day, _ hour: Int, _ minute: Int = 0) -> Date {
    day.date(hour: hour, calendar: testCalendar).addingTimeInterval(TimeInterval(minute * 60))
}

/// Deterministic pseudo-random normal draws (LCG + Box-Muller) so tests are reproducible.
struct SeededNormal {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }

    mutating func next() -> Double {
        let u1 = uniform(), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Builds a plausible record without going through HealthKit-shaped inputs.
func syntheticRecord(day: Day,
                     lnHRV: Double?,
                     sleepingHR: Double?,
                     appleRHR: Double? = 55,
                     respiratory: Double? = 14,
                     temperature: Double? = 34.5,
                     asleepHours: Double? = 7.5,
                     workoutMinutes: Double = 45,
                     workoutBPM: Int = 145) -> DayRecord {
    var sleep: SleepNight?
    if let h = asleepHours {
        let onset = at(day.adding(-1, calendar: testCalendar), 23)
        let wake = onset.addingTimeInterval(h * 3600 + 1200)
        sleep = SleepNight(asleep: h * 3600, awake: 1200, core: h * 3600 * 0.55, deep: h * 3600 * 0.2,
                           rem: h * 3600 * 0.25, unspecified: 0, mainOnset: onset, mainWake: wake,
                           mainAsleep: h * 3600)
    }
    let activity = HeartRateHistogram(secondsByBPM: [
        65: 14.0 * 3600,
        workoutBPM: workoutMinutes * 60,
    ])
    return DayRecord(day: day, sleep: sleep, lnHRV: lnHRV, hrvSampleCount: lnHRV == nil ? 0 : 3,
                     hrvDuringSleep: lnHRV != nil && sleep != nil, sleepingHR: sleepingHR,
                     appleRestingHR: appleRHR, respiratoryRate: respiratory, wristTemperature: temperature,
                     activity: activity)
}

/// `count` days ending on `today` with stable physiology plus noise.
func syntheticHistory(today: Day, count: Int, seed: UInt64 = 42) -> [DayRecord] {
    var rng = SeededNormal(seed: seed)
    return (0..<count).map { k in
        let d = today.adding(k - count + 1, calendar: testCalendar)
        return syntheticRecord(day: d,
                               lnHRV: log(55) + 0.10 * rng.next(),
                               sleepingHR: 50 + 1.5 * rng.next(),
                               respiratory: 14 + 0.4 * rng.next(),
                               temperature: 34.5 + 0.15 * rng.next(),
                               asleepHours: 7.6 + 0.4 * rng.next())
    }
}
