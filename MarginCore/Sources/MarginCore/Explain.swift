import Foundation

// MARK: - Why today changed

/// One recovery input's contribution today and on the previous scored day.
public struct DriverChange: Codable, Sendable, Equatable, Identifiable {
    public var kind: ComponentKind
    /// weight × oriented z (composite units). Nil when the input was missing that day.
    public var now: Double?
    public var before: Double?
    public var change: Double { (now ?? 0) - (before ?? 0) }
    public var id: String { kind.rawValue }
}

/// A plain-language explanation built only from the engine's own numbers.
/// No language model: each sentence is a template filled with computed values.
public struct RecoveryExplanation: Codable, Sendable, Equatable {
    public var headline: String
    public var lines: [String]
    public var drivers: [DriverChange]
    /// The scored day compared against, if any.
    public var comparedWith: Day?
}

public enum RecoveryExplainer {
    static func name(_ k: ComponentKind) -> String {
        switch k {
        case .hrv: return "HRV"
        case .restingHR: return "Sleeping heart rate"
        case .sleep: return "Sleep vs need"
        case .respiratoryRate: return "Respiratory rate"
        case .wristTemperature: return "Wrist temperature"
        }
    }

    static func value(_ c: Component) -> String {
        switch c.kind {
        case .hrv: return String(format: "%.0f ms vs usual %.0f", c.value, c.baseline ?? 0)
        case .restingHR: return String(format: "%.0f bpm vs usual %.0f", c.value, c.baseline ?? 0)
        case .sleep: return String(format: "%.0f%% of your need", c.value)
        case .respiratoryRate: return String(format: "%.1f/min vs usual %.1f", c.value, c.baseline ?? 0)
        case .wristTemperature: return String(format: "%+.2f °C vs usual", c.value - (c.baseline ?? c.value))
        }
    }

    public static func explain(today: Recovery, previous: (Day, Recovery)?, plan: Plan) -> RecoveryExplanation {
        guard let s = today.score else {
            return RecoveryExplanation(headline: today.statusDetail, lines: [], drivers: [], comparedWith: nil)
        }
        var headline = "Recovery \(s)"
        let prev = previous.flatMap { p in p.1.score.map { (p.0, p.1, $0) } }
        if let (_, _, ps) = prev {
            let d = s - ps
            headline += d == 0 ? ", same as last time (\(ps))." : ", \(d > 0 ? "up" : "down") \(abs(d)) from \(ps) last time."
        } else {
            headline += "."
        }
        var drivers: [DriverChange] = []
        for c in today.components {
            let before = prev?.1.components.first { $0.kind == c.kind }.map(\.contribution)
            drivers.append(DriverChange(kind: c.kind, now: c.contribution, before: before))
        }
        for c in prev?.1.components ?? [] where !today.components.contains(where: { $0.kind == c.kind }) {
            drivers.append(DriverChange(kind: c.kind, now: nil, before: c.contribution))
        }
        // Rank by what moved the score most (or, with no comparison, by what weighs most today).
        drivers.sort { abs(prev == nil ? ($0.now ?? 0) : $0.change) > abs(prev == nil ? ($1.now ?? 0) : $1.change) }
        var lines: [String] = []
        for d in drivers.prefix(3) {
            guard let c = today.components.first(where: { $0.kind == d.kind }) else {
                lines.append("\(name(d.kind)): no reading last night, so it no longer counts.")
                continue
            }
            let effect = (prev == nil ? (d.now ?? 0) : d.change)
            guard abs(effect) >= 0.02 else { continue }
            let verb = effect > 0 ? (prev == nil ? "lifts" : "lifted") : (prev == nil ? "lowers" : "lowered")
            lines.append("\(name(c.kind)) \(value(c)) (\(String(format: "%+.1f", c.z)) SD) \(verb) the score.")
        }
        if lines.isEmpty { lines.append("All inputs are close to your usual, so the score barely moved.") }
        for f in today.flags {
            switch f {
            case .sleepDebt: lines.append("You're carrying sleep debt from the last 7 nights.")
            case .hrvTrendLow: lines.append("Your 7-day HRV average is below your normal range.")
            case .loadSpike: lines.append("Recent load is well above your 42-day average.")
            case .elevatedVitals: lines.append("Sleeping heart rate and temperature or respiration were well above usual.")
            }
        }
        lines += plan.reasons
        return RecoveryExplanation(headline: headline, lines: lines, drivers: drivers, comparedWith: prev?.0)
    }
}

// MARK: - Workout analysis

public struct WorkoutAnalysis: Codable, Sendable, Equatable {
    /// Banister TRIMP of this workout alone.
    public var load: Double
    /// Strain this workout would be on its own (same reference as the day's strain).
    public var strain: Int
    /// Minutes in zones 0-5.
    public var zoneMinutes: [Double]
    public var focus: CardioFocus?
    /// 30 s points: seconds from start, bpm, zone index (0-5).
    public var curve: [CurvePoint]
    /// Zone lower bounds used, bpm.
    public var bounds: [Double]

    public struct CurvePoint: Codable, Sendable, Equatable, Identifiable {
        public var seconds: Double
        public var bpm: Double
        public var zone: Int
        /// True for points after the workout ended (recovery).
        public var afterEnd: Bool
        public var id: Double { seconds }
    }

    public static func make(_ w: WorkoutDetail, hrRest: Double, hrMax: Double, sex: Sex, floorHRR: Double,
                            zones: ZoneSettings, strainReference: Double) -> WorkoutAnalysis {
        let h = HeartRateHistogram(secondsByBPM: w.hrSeconds)
        let load = h.trimp(hrRest: hrRest, hrMax: hrMax, sex: sex, floorHRR: floorHRR) ?? 0
        let bounds = zones.bpmBounds(hrRest: hrRest, hrMax: hrMax)
        let z = ZoneModel.zoneSeconds(bpmSeconds: w.hrSeconds, bounds: bounds)
        let duration = w.end.timeIntervalSince(w.start)
        let curve: [CurvePoint] = (w.hrCurve ?? []).enumerated().compactMap { k, v in
            guard let bpm = v else { return nil }
            let zone = bounds.lastIndex { bpm >= $0 }.map { $0 + 1 } ?? 0
            let t = Double(k) * 30
            return CurvePoint(seconds: t, bpm: bpm, zone: zone, afterEnd: t >= duration)
        }
        return WorkoutAnalysis(load: load, strain: Int(StrainModel.score(load: load, reference: strainReference).rounded()),
                               zoneMinutes: z.map { $0 / 60 }, focus: CardioFocus.classify(zoneSeconds: z), curve: curve, bounds: bounds)
    }
}

// MARK: - Routine sync between iPhone and watch

extension RoutineLibrary {
    /// Merges another copy of the library (e.g. edits made on iPhone). Per
    /// routine, the newer `updatedAt` wins; a deletion wins over any edit made
    /// before it. Deterministic and order-independent.
    public func merged(with other: RoutineLibrary) -> RoutineLibrary {
        var tomb = deleted ?? [:]
        for (id, at) in other.deleted ?? [:] { tomb[id] = max(tomb[id] ?? at, at) }
        var byID: [UUID: Routine] = [:]
        for r in routines + other.routines {
            if let cur = byID[r.id], (cur.updatedAt, cur.name) >= (r.updatedAt, r.name) { continue }
            byID[r.id] = r
        }
        let kept = byID.values.filter { r in tomb[r.id].map { r.updatedAt > $0 } ?? true }
        return RoutineLibrary(routines: kept.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) },
                              deleted: tomb.isEmpty ? nil : tomb)
    }
}

// MARK: - Sleep history

public struct SleepHistoryNight: Codable, Sendable, Equatable, Identifiable {
    public var day: Day
    public var summary: SleepSummary
    public var stages: [StageSpan]
    public var id: String { day.description }
}
