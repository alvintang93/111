import Foundation

/// Sorted, non-overlapping intervals. Used to test whether a heart-rate sample
/// fell during sleep, a workout or movement, and to measure overlaps.
struct IntervalSet: Sendable {
    private(set) var intervals: [DateInterval] = []

    init(_ raw: [DateInterval]) {
        for i in raw.sorted(by: { $0.start < $1.start }) where i.duration > 0 {
            if let last = intervals.last, i.start <= last.end {
                if i.end > last.end { intervals[intervals.count - 1] = DateInterval(start: last.start, end: i.end) }
            } else {
                intervals.append(i)
            }
        }
    }

    func contains(_ d: Date) -> Bool {
        var lo = 0, hi = intervals.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let i = intervals[mid]
            if d < i.start { hi = mid - 1 } else if d >= i.end { lo = mid + 1 } else { return true }
        }
        return false
    }

    func overlap(with w: DateInterval) -> TimeInterval {
        var total = 0.0
        for i in intervals where i.end > w.start && i.start < w.end {
            total += min(i.end, w.end).timeIntervalSince(max(i.start, w.start))
        }
        return total
    }
}

/// One hour of the activity window. Stored instead of raw samples so stress,
/// strain-by-hour and energy can be recomputed when HRrest or HRmax change,
/// without a new HealthKit query.
public struct HourSlice: Codable, Sendable, Equatable {
    /// Whole hours since the start of the day's activity window.
    public var hour: Int
    /// Seconds at heart rate in 10-bpm bins, keyed by bpm / 10. Sparse.
    public var hrBins: [Int: Double]
    /// Heart-rate time while awake, still (no stepping) and outside workouts.
    public var restSeconds: Double
    /// Sum of bpm × seconds over `restSeconds`.
    public var restBPMSeconds: Double
    public var asleepSeconds: Double
    public var workoutSeconds: Double
    public var steps: Double

    public init(hour: Int, hrBins: [Int: Double] = [:], restSeconds: Double = 0, restBPMSeconds: Double = 0,
                asleepSeconds: Double = 0, workoutSeconds: Double = 0, steps: Double = 0) {
        self.hour = hour
        self.hrBins = hrBins
        self.restSeconds = restSeconds
        self.restBPMSeconds = restBPMSeconds
        self.asleepSeconds = asleepSeconds
        self.workoutSeconds = workoutSeconds
        self.steps = steps
    }

    public var hrSeconds: Double { hrBins.keys.sorted().reduce(0) { $0 + hrBins[$1]! } }
    public var restMeanBPM: Double? { restSeconds > 0 ? restBPMSeconds / restSeconds : nil }

    var isEmpty: Bool { hrBins.isEmpty && asleepSeconds == 0 && workoutSeconds == 0 && steps == 0 }

    /// Banister TRIMP for the hour, using each 10-bpm bin's midpoint.
    func trimp(hrRest: Double, hrMax: Double, sex: Sex, floorHRR: Double) -> Double {
        guard hrMax - hrRest >= 20 else { return 0 }
        let (a, b) = HeartRateHistogram.banisterCoefficients(sex)
        var total = 0.0
        for bin in hrBins.keys.sorted() {
            let hrr = (Double(bin * 10) + 5 - hrRest) / (hrMax - hrRest)
            guard hrr >= floorHRR else { continue }
            let x = min(hrr, 1)
            total += (hrBins[bin]! / 60) * x * a * exp(b * x)
        }
        return total
    }
}

public enum HourSliceBuilder {
    /// Splits the activity window into hours. Each heart-rate sample holds
    /// until the next one (capped at `maxSampleGap`), exactly as the daily
    /// histogram does, so the slices' heart-rate time adds up to the histogram's.
    public static func build(heartRate: [HRSample], steps: [TimedValue], sleep: [SleepSegment],
                             workouts: [WorkoutSample], window: DateInterval,
                             params: ModelParameters = .standard) -> [HourSlice] {
        let hourCount = Int((window.duration / 3600).rounded(.up))
        guard hourCount > 0 else { return [] }
        var slices = (0..<hourCount).map { HourSlice(hour: $0) }

        let asleep = IntervalSet(sleep.filter(\.stage.isAsleep).map { DateInterval(start: $0.start, end: $0.end) })
        let workoutSet = IntervalSet(workouts.map { DateInterval(start: $0.start, end: $0.end) })
        var notRest = sleep.filter { $0.stage.isAsleep || $0.stage == .inBed }.map { DateInterval(start: $0.start, end: $0.end) }
        notRest += workouts.map { DateInterval(start: $0.start, end: $0.end.addingTimeInterval(params.workoutSettleTime)) }
        for s in steps where s.value > 0 {
            let d = s.end.timeIntervalSince(s.start)
            let moving = d >= 30 ? s.value / (d / 60) >= params.movingCadence : s.value >= params.movingCadence / 2
            if moving {
                notRest.append(DateInterval(start: s.start, end: s.end.addingTimeInterval(params.movementSettleTime)))
            }
        }
        let notRestSet = IntervalSet(notRest)

        func hourIndex(_ d: Date) -> Int { Int(d.timeIntervalSince(window.start) / 3600) }
        func hourStart(_ h: Int) -> Date { window.start.addingTimeInterval(Double(h) * 3600) }

        let inWindow = heartRate
            .filter { $0.date >= window.start && $0.date < window.end && $0.bpm.isFinite && $0.bpm > 0 }
            .sorted { $0.date < $1.date }
        for (i, s) in inWindow.enumerated() {
            let next = i + 1 < inWindow.count ? inWindow[i + 1].date : window.end
            let dt = min(max(next.timeIntervalSince(s.date), 0), params.maxSampleGap)
            guard dt > 0 else { continue }
            let bin = min(max(Int(s.bpm.rounded()), 0), HeartRateHistogram.maxBPM) / 10
            var a = s.date
            let end = s.date.addingTimeInterval(dt)
            while a < end {
                let h = hourIndex(a)
                guard h < hourCount else { break }
                let b = min(end, hourStart(h + 1), window.end)
                let len = b.timeIntervalSince(a)
                guard len > 0 else { break }
                slices[h].hrBins[bin, default: 0] += len
                if !notRestSet.contains(a.addingTimeInterval(len / 2)) {
                    slices[h].restSeconds += len
                    slices[h].restBPMSeconds += s.bpm * len
                }
                a = b
            }
        }

        for h in 0..<hourCount {
            let w = DateInterval(start: hourStart(h), end: min(hourStart(h + 1), window.end))
            slices[h].asleepSeconds = asleep.overlap(with: w)
            slices[h].workoutSeconds = workoutSet.overlap(with: w)
        }
        for s in steps where s.value > 0 {
            let d = s.end.timeIntervalSince(s.start)
            if d <= 0 {
                guard s.start >= window.start, s.start < window.end else { continue }
                slices[min(hourIndex(s.start), hourCount - 1)].steps += s.value
                continue
            }
            guard s.end > window.start, s.start < window.end else { continue }
            for h in max(0, hourIndex(max(s.start, window.start)))..<hourCount {
                let w = DateInterval(start: hourStart(h), end: min(hourStart(h + 1), window.end))
                guard w.start < s.end else { break }
                let ov = min(s.end, w.end).timeIntervalSince(max(s.start, w.start))
                if ov > 0 { slices[h].steps += s.value * ov / d }
            }
        }
        return slices.filter { !$0.isEmpty }
    }
}

// MARK: - Workouts

/// One workout with heart-rate recovery measured after it ended.
public struct WorkoutDetail: Codable, Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    /// `HKWorkoutActivityType.rawValue`.
    public var activityType: UInt
    public var averageHR: Double?
    public var peakHR: Double?
    /// Highest heart rate in the last minute of the workout.
    public var endHR: Double?
    /// Heart rate about 60 s and 120 s after the workout ended.
    public var hr60: Double?
    public var hr120: Double?
    /// Apple's one-minute heart-rate recovery for this workout, when Health has one.
    public var appleRecovery1: Double?
    /// HealthKit workout UUID and source (identity and provenance).
    public var healthID: UUID?
    public var source: String?
    /// Seconds at each whole bpm during the workout (sparse), for time in zone with any zone settings.
    public var hrSeconds: [Int: Double]

    public init(start: Date, end: Date, activityType: UInt, averageHR: Double? = nil, peakHR: Double? = nil,
                endHR: Double? = nil, hr60: Double? = nil, hr120: Double? = nil, appleRecovery1: Double? = nil,
                hrSeconds: [Int: Double] = [:]) {
        self.start = start
        self.end = end
        self.activityType = activityType
        self.averageHR = averageHR
        self.peakHR = peakHR
        self.endHR = endHR
        self.hr60 = hr60
        self.hr120 = hr120
        self.appleRecovery1 = appleRecovery1
        self.hrSeconds = hrSeconds
    }

    public var id: Date { start }
    public var minutes: Double { end.timeIntervalSince(start) / 60 }

    public var drop60: Double? {
        guard let e = endHR, let h = hr60 else { return nil }
        return e - h
    }

    public var drop120: Double? {
        guard let e = endHR, let h = hr120 else { return nil }
        return e - h
    }

    /// Apple's value when present (it uses the full post-workout recording), else Margin's 60 s drop.
    public var recovery1: Double? { appleRecovery1 ?? drop60 }
}

public enum WorkoutRecoveryAnalyzer {
    public static func analyze(workouts: [WorkoutSample], heartRate: [HRSample], appleRecovery: [TimedValue],
                               params: ModelParameters = .standard) -> [WorkoutDetail] {
        let hr = heartRate.sorted { $0.date < $1.date }
        func samples(_ from: Date, _ to: Date) -> [HRSample] {
            hr.filter { $0.date >= from && $0.date <= to }
        }
        func nearest(to t: Date, within tol: TimeInterval) -> Double? {
            samples(t.addingTimeInterval(-tol), t.addingTimeInterval(tol))
                .min { abs($0.date.timeIntervalSince(t)) < abs($1.date.timeIntervalSince(t)) }?.bpm
        }
        return workouts.sorted { $0.start < $1.start }.map { w in
            let during = samples(w.start, w.end).map(\.bpm)
            var endHR = samples(w.end.addingTimeInterval(-60), w.end).map(\.bpm).max()
            if endHR == nil { endHR = samples(w.end.addingTimeInterval(-120), w.end).last?.bpm }
            let apple = appleRecovery
                .filter { $0.start >= w.end.addingTimeInterval(-60) && $0.start <= w.end.addingTimeInterval(params.appleRecoveryMatchWindow) }
                .min { abs($0.start.timeIntervalSince(w.end)) < abs($1.start.timeIntervalSince(w.end)) }?.value
            let histogram = HeartRateHistogram.build(samples: hr, window: DateInterval(start: w.start, end: max(w.end, w.start)),
                                                     maxGap: params.maxSampleGap)
            var bins: [Int: Double] = [:]
            for (bpm, sec) in histogram.seconds.enumerated() where sec > 0 { bins[bpm] = sec }
            var d = WorkoutDetail(start: w.start, end: w.end, activityType: w.activityType,
                                  averageHR: Stats.mean(during), peakHR: during.max(), endHR: endHR,
                                  hr60: nearest(to: w.end.addingTimeInterval(60), within: 15),
                                  hr120: nearest(to: w.end.addingTimeInterval(120), within: 20),
                                  appleRecovery1: apple, hrSeconds: bins)
            d.healthID = w.healthID
            d.source = w.source
            return d
        }
    }
}

/// Names for common `HKWorkoutActivityType` raw values (stable HealthKit constants).
public enum WorkoutType {
    public static func name(_ raw: UInt) -> String {
        switch raw {
        case 1: return "Football"
        case 6: return "Basketball"
        case 11: return "Cross training"
        case 13: return "Cycling"
        case 16: return "Elliptical"
        case 20: return "Functional strength"
        case 24: return "Hiking"
        case 35: return "Rowing"
        case 37: return "Running"
        case 41: return "Soccer"
        case 44: return "Stair climbing"
        case 46: return "Swimming"
        case 48: return "Tennis"
        case 50: return "Strength training"
        case 52: return "Walking"
        case 57: return "Yoga"
        case 59: return "Core training"
        case 62: return "Flexibility"
        case 63: return "HIIT"
        case 66: return "Pilates"
        case 73: return "Mixed cardio"
        case 77: return "Dance"
        case 79: return "Pickleball"
        case 80: return "Cooldown"
        default: return "Workout"
        }
    }
}
