import Foundation
import MarginCore

/// Short plain-text summaries of Margin's data for the on-device model, whose
/// context window is small. Every number is one Margin already computed.
enum CoachContext {
    static func f(_ v: Double?, _ digits: Int = 0) -> String {
        v.map { String(format: "%.\(digits)f", $0) } ?? "n/a"
    }

    static func today(_ b: DailyBrief) -> String {
        var lines: [String] = []
        lines.append("Data for \(b.day)\(b.isCurrent() ? "" : " (not today: the watch hasn't synced yet today)").")
        let r = b.recovery
        lines.append("Recovery: \(r.score.map { "\($0)/100" } ?? "no score") (\(r.status.rawValue): \(r.statusDetail)).")
        for c in r.components {
            lines.append("- \(c.kind.rawValue): \(f(c.value, 1)) vs baseline \(f(c.baseline, 1)), z \(f(c.z, 1))")
        }
        lines.append("Directive: \(b.plan.directive.rawValue). Load target \(f(b.plan.targetLow))-\(f(b.plan.targetHigh)) TRIMP. \(b.plan.reasons.joined(separator: " "))")
        if !r.flags.isEmpty { lines.append("Flags: \(r.flags.map(\.rawValue).joined(separator: ", ")).") }
        if let s = b.sleep {
            lines.append("Sleep: \(f(s.asleepHours, 1)) h of \(f(s.needHours, 1)) h need, score \(s.score), deep \(f(s.deepMinutes)) min, REM \(f(s.remMinutes)) min, 7-night debt \(f(s.debtHours, 1)) h.")
        }
        if let st = b.strain { lines.append("Strain: \(st.score.map(String.init) ?? "n/a")/100, target \(st.targetLow.map(String.init) ?? "?")-\(st.targetHigh.map(String.init) ?? "?").") }
        if let s = b.stress { lines.append("Stress: now \(s.current.map(String.init) ?? "n/a"), day \(s.score.map(String.init) ?? "n/a").") }
        if let e = b.energy { lines.append("Energy: \(e.current)/100 (started \(e.start)).") }
        lines.append("Load: today \(f(b.load.todayLoad)), ATL \(f(b.load.atl)), CTL \(f(b.load.ctl)), ACWR \(f(b.load.acwr, 2)).")
        if let i = b.intake {
            lines.append("Caffeine now \(f(i.caffeineNowMg)) mg, at bedtime \(f(i.caffeineAtBedtimeMg)) mg. Water \(f(i.waterTodayMl)) of \(f(i.waterTargetMl)) ml.")
        }
        if let st = b.statuses, !st.isEmpty { lines.append("Marked: \(st.map(\.rawValue).joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    static func history(_ b: DailyBrief, metric: CompareMetric, days: Int) -> String {
        guard let s = b.series?.first(where: { $0.metric == metric }), !s.points.isEmpty else { return "No \(metric.title) data." }
        let pts = s.points.suffix(days)
        return "\(metric.title), last \(pts.count) days: " + pts.map { "\($0.day.description.suffix(5)) \(f($0.value, 1))" }.joined(separator: ", ")
    }

    static func body(_ b: DailyBrief) -> String {
        guard let bio = b.biomarkers else { return "No body data yet." }
        var lines: [String] = []
        func trend(_ name: String, _ t: Trend?, _ unit: String, _ d: Int) {
            guard let t else { return }
            lines.append("\(name): \(f(t.latest, d)) \(unit)" + (t.slopePerWeek.map { ", \(f($0, 2))/week" } ?? ""))
        }
        if let a = bio.biologicalAge {
            lines.append("Biological age estimate \(f(a.estimate)) (age \(a.chronological)): " + a.components.map { "\($0.name) \(f($0.years, 1)) y" }.joined(separator: ", "))
        }
        trend("VO2 max", bio.vo2Max, "mL/kg/min", 1)
        trend("Resting HR", bio.restingHR, "bpm", 0)
        trend("Body mass", bio.bodyMass, "kg", 1)
        trend("Body fat", bio.bodyFat, "%", 1)
        if let bp = bio.bloodPressure { lines.append("Blood pressure \(f(bp.latestSystolic))/\(f(bp.latestDiastolic)) (\(bp.category.rawValue)).") }
        if let g = bio.glucose { lines.append("Glucose \(f(g.latest)) mg/dL.") }
        if let n = bio.nutrition?.average7 { lines.append("Food 7-day avg: \(f(n.energyKcal)) kcal, protein \(f(n.proteinG)) g.") }
        if let c = bio.cycle { lines.append("Cycle day \(c.cycleDay), \(c.phase.rawValue) phase.") }
        if let r = bio.running { lines.append("Last run: cadence \(f(r.latest.cadence)) spm, pace \(f(r.latest.pace, 2)) min/km.") }
        return lines.isEmpty ? "No body data yet." : lines.joined(separator: "\n")
    }

    static func strength(_ b: DailyBrief) -> String {
        guard let s = b.strength else { return "No strength workouts logged." }
        var lines = ["Muscles (freshness 0-100, ready at 80+): " + s.muscles.sorted { $0.freshness < $1.freshness }
            .map { "\($0.muscle.title) \($0.freshness)" }.joined(separator: ", ")]
        lines.append("Best e1RM: " + s.records.prefix(5).map { "\($0.name) \(f($0.e1RM)) kg" }.joined(separator: ", "))
        if let l = s.lastSession { lines.append("Last session \(l.start.formatted(date: .abbreviated, time: .omitted)): \(l.sets) sets, \(l.exercises.joined(separator: ", ")).") }
        return lines.joined(separator: "\n")
    }

    static func labs(_ labs: [LabResult]) -> String {
        let series = LabSeries.group(labs)
        guard !series.isEmpty else { return "No lab results entered." }
        return series.prefix(12).map { s in
            let r = s.latest
            let range = (r.referenceLow != nil || r.referenceHigh != nil) ? " (report range \(f(r.referenceLow, 1))-\(f(r.referenceHigh, 1)))" : ""
            return "\(s.name): \(f(r.value, 1)) \(s.unit) on \(r.date.formatted(date: .abbreviated, time: .omitted))\(range)"
        }.joined(separator: "\n")
    }
}
