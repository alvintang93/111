import Foundation

public enum Muscle: String, Codable, Sendable, CaseIterable {
    case chest, frontDelts, sideDelts, rearDelts, biceps, triceps, forearms
    case upperBack, lats, lowerBack, abs, obliques, glutes, quads, hamstrings, calves

    public var title: String {
        switch self {
        case .chest: return "Chest"
        case .frontDelts: return "Front delts"
        case .sideDelts: return "Side delts"
        case .rearDelts: return "Rear delts"
        case .biceps: return "Biceps"
        case .triceps: return "Triceps"
        case .forearms: return "Forearms"
        case .upperBack: return "Upper back"
        case .lats: return "Lats"
        case .lowerBack: return "Lower back"
        case .abs: return "Abs"
        case .obliques: return "Obliques"
        case .glutes: return "Glutes"
        case .quads: return "Quads"
        case .hamstrings: return "Hamstrings"
        case .calves: return "Calves"
        }
    }

    /// Larger muscle groups take longer to recover (fatigue time constant, hours).
    public var recoveryHours: Double {
        switch self {
        case .chest, .upperBack, .lats, .lowerBack, .glutes, .quads, .hamstrings: return 30
        case .frontDelts, .sideDelts, .rearDelts, .biceps, .triceps, .forearms, .abs, .obliques, .calves: return 20
        }
    }
}

public enum Equipment: String, Codable, Sendable, CaseIterable {
    case barbell, dumbbell, machine, cable, bodyweight, kettlebell, band, other
}

public struct Exercise: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var equipment: Equipment
    public var primary: [Muscle]
    public var secondary: [Muscle]
    /// For bodyweight movements: share of body mass moved (added weight is on top).
    public var bodyweightFactor: Double

    public init(_ id: String, _ name: String, _ equipment: Equipment, _ primary: [Muscle], _ secondary: [Muscle] = [],
                bodyweight: Double = 0) {
        self.id = id
        self.name = name
        self.equipment = equipment
        self.primary = primary
        self.secondary = secondary
        self.bodyweightFactor = bodyweight
    }
}

/// Built-in movements. IDs are stable: logged sets refer to them.
public enum ExerciseLibrary {
    public static let all: [Exercise] = chest + back + shoulders + arms + legs + core + fullBody

    public static let byID: [String: Exercise] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func exercises(for muscle: Muscle) -> [Exercise] {
        all.filter { $0.primary.contains(muscle) }
    }

    static let chest: [Exercise] = [
        Exercise("bench-press", "Bench press", .barbell, [.chest], [.frontDelts, .triceps]),
        Exercise("incline-bench", "Incline bench press", .barbell, [.chest, .frontDelts], [.triceps]),
        Exercise("decline-bench", "Decline bench press", .barbell, [.chest], [.triceps]),
        Exercise("close-grip-bench", "Close-grip bench press", .barbell, [.triceps, .chest], [.frontDelts]),
        Exercise("db-bench", "Dumbbell bench press", .dumbbell, [.chest], [.frontDelts, .triceps]),
        Exercise("db-incline-bench", "Incline dumbbell press", .dumbbell, [.chest, .frontDelts], [.triceps]),
        Exercise("db-fly", "Dumbbell fly", .dumbbell, [.chest], [.frontDelts]),
        Exercise("machine-chest-press", "Machine chest press", .machine, [.chest], [.frontDelts, .triceps]),
        Exercise("pec-deck", "Pec deck", .machine, [.chest]),
        Exercise("cable-fly", "Cable fly", .cable, [.chest], [.frontDelts]),
        Exercise("cable-crossover-low", "Low-to-high cable fly", .cable, [.chest, .frontDelts]),
        Exercise("push-up", "Push-up", .bodyweight, [.chest], [.triceps, .frontDelts, .abs], bodyweight: 0.64),
        Exercise("dip", "Dip", .bodyweight, [.chest, .triceps], [.frontDelts], bodyweight: 1.0),
        Exercise("smith-bench", "Smith machine bench press", .machine, [.chest], [.frontDelts, .triceps]),
    ]

    static let back: [Exercise] = [
        Exercise("deadlift", "Deadlift", .barbell, [.hamstrings, .glutes, .lowerBack], [.upperBack, .lats, .forearms, .quads]),
        Exercise("barbell-row", "Barbell row", .barbell, [.upperBack, .lats], [.biceps, .rearDelts, .lowerBack]),
        Exercise("pendlay-row", "Pendlay row", .barbell, [.upperBack, .lats], [.biceps, .rearDelts, .lowerBack]),
        Exercise("tbar-row", "T-bar row", .barbell, [.upperBack, .lats], [.biceps, .rearDelts]),
        Exercise("db-row", "One-arm dumbbell row", .dumbbell, [.lats, .upperBack], [.biceps, .rearDelts]),
        Exercise("chest-supported-row", "Chest-supported row", .dumbbell, [.upperBack], [.lats, .rearDelts, .biceps]),
        Exercise("seated-cable-row", "Seated cable row", .cable, [.upperBack, .lats], [.biceps, .rearDelts]),
        Exercise("lat-pulldown", "Lat pulldown", .cable, [.lats], [.biceps, .upperBack]),
        Exercise("close-grip-pulldown", "Close-grip pulldown", .cable, [.lats], [.biceps]),
        Exercise("straight-arm-pulldown", "Straight-arm pulldown", .cable, [.lats], [.triceps]),
        Exercise("pull-up", "Pull-up", .bodyweight, [.lats], [.biceps, .upperBack, .forearms], bodyweight: 1.0),
        Exercise("chin-up", "Chin-up", .bodyweight, [.lats, .biceps], [.upperBack], bodyweight: 1.0),
        Exercise("inverted-row", "Inverted row", .bodyweight, [.upperBack], [.lats, .biceps, .rearDelts], bodyweight: 0.6),
        Exercise("machine-row", "Machine row", .machine, [.upperBack, .lats], [.biceps, .rearDelts]),
        Exercise("assisted-pull-up", "Assisted pull-up", .machine, [.lats], [.biceps, .upperBack]),
        Exercise("shrug", "Barbell shrug", .barbell, [.upperBack], [.forearms]),
        Exercise("db-shrug", "Dumbbell shrug", .dumbbell, [.upperBack], [.forearms]),
        Exercise("back-extension", "Back extension", .bodyweight, [.lowerBack, .glutes], [.hamstrings], bodyweight: 0.5),
        Exercise("rack-pull", "Rack pull", .barbell, [.upperBack, .lowerBack], [.glutes, .hamstrings, .forearms]),
        Exercise("good-morning", "Good morning", .barbell, [.hamstrings, .lowerBack], [.glutes]),
    ]

    static let shoulders: [Exercise] = [
        Exercise("overhead-press", "Overhead press", .barbell, [.frontDelts], [.sideDelts, .triceps, .upperBack]),
        Exercise("push-press", "Push press", .barbell, [.frontDelts], [.triceps, .sideDelts, .quads]),
        Exercise("db-shoulder-press", "Dumbbell shoulder press", .dumbbell, [.frontDelts], [.sideDelts, .triceps]),
        Exercise("arnold-press", "Arnold press", .dumbbell, [.frontDelts, .sideDelts], [.triceps]),
        Exercise("machine-shoulder-press", "Machine shoulder press", .machine, [.frontDelts], [.sideDelts, .triceps]),
        Exercise("lateral-raise", "Lateral raise", .dumbbell, [.sideDelts]),
        Exercise("cable-lateral-raise", "Cable lateral raise", .cable, [.sideDelts]),
        Exercise("machine-lateral-raise", "Machine lateral raise", .machine, [.sideDelts]),
        Exercise("front-raise", "Front raise", .dumbbell, [.frontDelts]),
        Exercise("rear-delt-fly", "Rear delt fly", .dumbbell, [.rearDelts], [.upperBack]),
        Exercise("reverse-pec-deck", "Reverse pec deck", .machine, [.rearDelts], [.upperBack]),
        Exercise("face-pull", "Face pull", .cable, [.rearDelts, .upperBack], [.sideDelts]),
        Exercise("upright-row", "Upright row", .barbell, [.sideDelts, .upperBack], [.biceps]),
        Exercise("pike-push-up", "Pike push-up", .bodyweight, [.frontDelts], [.triceps], bodyweight: 0.7),
    ]

    static let arms: [Exercise] = [
        Exercise("barbell-curl", "Barbell curl", .barbell, [.biceps], [.forearms]),
        Exercise("ez-curl", "EZ-bar curl", .barbell, [.biceps], [.forearms]),
        Exercise("db-curl", "Dumbbell curl", .dumbbell, [.biceps], [.forearms]),
        Exercise("hammer-curl", "Hammer curl", .dumbbell, [.biceps, .forearms]),
        Exercise("incline-curl", "Incline dumbbell curl", .dumbbell, [.biceps]),
        Exercise("preacher-curl", "Preacher curl", .barbell, [.biceps]),
        Exercise("cable-curl", "Cable curl", .cable, [.biceps], [.forearms]),
        Exercise("concentration-curl", "Concentration curl", .dumbbell, [.biceps]),
        Exercise("tricep-pushdown", "Triceps pushdown", .cable, [.triceps]),
        Exercise("rope-pushdown", "Rope pushdown", .cable, [.triceps]),
        Exercise("overhead-cable-extension", "Overhead cable extension", .cable, [.triceps]),
        Exercise("skull-crusher", "Skull crusher", .barbell, [.triceps]),
        Exercise("db-overhead-extension", "Dumbbell overhead extension", .dumbbell, [.triceps]),
        Exercise("bench-dip", "Bench dip", .bodyweight, [.triceps], [.chest, .frontDelts], bodyweight: 0.6),
        Exercise("diamond-push-up", "Diamond push-up", .bodyweight, [.triceps, .chest], [.frontDelts], bodyweight: 0.64),
        Exercise("wrist-curl", "Wrist curl", .dumbbell, [.forearms]),
        Exercise("reverse-curl", "Reverse curl", .barbell, [.forearms, .biceps]),
        Exercise("farmer-carry", "Farmer's carry", .dumbbell, [.forearms, .upperBack], [.abs, .glutes]),
    ]

    static let legs: [Exercise] = [
        Exercise("back-squat", "Back squat", .barbell, [.quads, .glutes], [.hamstrings, .lowerBack, .abs]),
        Exercise("front-squat", "Front squat", .barbell, [.quads], [.glutes, .abs, .upperBack]),
        Exercise("high-bar-squat", "High-bar squat", .barbell, [.quads, .glutes], [.lowerBack]),
        Exercise("goblet-squat", "Goblet squat", .dumbbell, [.quads, .glutes], [.abs]),
        Exercise("hack-squat", "Hack squat", .machine, [.quads], [.glutes]),
        Exercise("leg-press", "Leg press", .machine, [.quads, .glutes], [.hamstrings]),
        Exercise("smith-squat", "Smith machine squat", .machine, [.quads, .glutes]),
        Exercise("bulgarian-split-squat", "Bulgarian split squat", .dumbbell, [.quads, .glutes], [.hamstrings]),
        Exercise("walking-lunge", "Walking lunge", .dumbbell, [.quads, .glutes], [.hamstrings]),
        Exercise("reverse-lunge", "Reverse lunge", .dumbbell, [.glutes, .quads], [.hamstrings]),
        Exercise("step-up", "Step-up", .dumbbell, [.quads, .glutes]),
        Exercise("leg-extension", "Leg extension", .machine, [.quads]),
        Exercise("romanian-deadlift", "Romanian deadlift", .barbell, [.hamstrings, .glutes], [.lowerBack, .forearms]),
        Exercise("db-rdl", "Dumbbell Romanian deadlift", .dumbbell, [.hamstrings, .glutes], [.lowerBack]),
        Exercise("stiff-leg-deadlift", "Stiff-leg deadlift", .barbell, [.hamstrings], [.glutes, .lowerBack]),
        Exercise("sumo-deadlift", "Sumo deadlift", .barbell, [.glutes, .quads, .hamstrings], [.lowerBack, .upperBack, .forearms]),
        Exercise("trap-bar-deadlift", "Trap-bar deadlift", .barbell, [.quads, .glutes, .hamstrings], [.lowerBack, .upperBack, .forearms]),
        Exercise("lying-leg-curl", "Lying leg curl", .machine, [.hamstrings]),
        Exercise("seated-leg-curl", "Seated leg curl", .machine, [.hamstrings]),
        Exercise("nordic-curl", "Nordic curl", .bodyweight, [.hamstrings], bodyweight: 0.7),
        Exercise("hip-thrust", "Hip thrust", .barbell, [.glutes], [.hamstrings]),
        Exercise("glute-bridge", "Glute bridge", .bodyweight, [.glutes], [.hamstrings], bodyweight: 0.5),
        Exercise("cable-kickback", "Cable kickback", .cable, [.glutes]),
        Exercise("hip-abduction", "Hip abduction machine", .machine, [.glutes]),
        Exercise("standing-calf-raise", "Standing calf raise", .machine, [.calves]),
        Exercise("seated-calf-raise", "Seated calf raise", .machine, [.calves]),
        Exercise("leg-press-calf-raise", "Leg press calf raise", .machine, [.calves]),
        Exercise("single-leg-calf-raise", "Single-leg calf raise", .bodyweight, [.calves], bodyweight: 1.0),
        Exercise("db-calf-raise", "Dumbbell calf raise", .dumbbell, [.calves]),
        Exercise("bodyweight-squat", "Bodyweight squat", .bodyweight, [.quads, .glutes], bodyweight: 0.7),
        Exercise("pistol-squat", "Pistol squat", .bodyweight, [.quads, .glutes], [.abs], bodyweight: 0.9),
        Exercise("kb-swing", "Kettlebell swing", .kettlebell, [.glutes, .hamstrings], [.lowerBack, .abs, .forearms]),
    ]

    static let core: [Exercise] = [
        Exercise("plank", "Plank (seconds as reps)", .bodyweight, [.abs], [.obliques]),
        Exercise("side-plank", "Side plank (seconds as reps)", .bodyweight, [.obliques], [.abs]),
        Exercise("crunch", "Crunch", .bodyweight, [.abs], bodyweight: 0.3),
        Exercise("cable-crunch", "Cable crunch", .cable, [.abs]),
        Exercise("hanging-leg-raise", "Hanging leg raise", .bodyweight, [.abs], [.obliques, .forearms], bodyweight: 0.35),
        Exercise("ab-wheel", "Ab wheel rollout", .other, [.abs], [.lats, .obliques], bodyweight: 0.5),
        Exercise("russian-twist", "Russian twist", .bodyweight, [.obliques], [.abs], bodyweight: 0.3),
        Exercise("pallof-press", "Pallof press", .cable, [.obliques, .abs]),
        Exercise("dead-bug", "Dead bug", .bodyweight, [.abs], bodyweight: 0.2),
        Exercise("decline-sit-up", "Decline sit-up", .bodyweight, [.abs], [.obliques], bodyweight: 0.4),
        Exercise("woodchop", "Cable woodchop", .cable, [.obliques], [.abs]),
    ]

    static let fullBody: [Exercise] = [
        Exercise("power-clean", "Power clean", .barbell, [.glutes, .hamstrings, .upperBack], [.quads, .lowerBack, .forearms, .frontDelts]),
        Exercise("clean-and-jerk", "Clean and jerk", .barbell, [.quads, .glutes, .frontDelts], [.upperBack, .hamstrings, .triceps]),
        Exercise("snatch", "Snatch", .barbell, [.glutes, .hamstrings, .upperBack], [.quads, .frontDelts, .lowerBack]),
        Exercise("thruster", "Thruster", .barbell, [.quads, .frontDelts], [.glutes, .triceps]),
        Exercise("kb-clean-press", "Kettlebell clean and press", .kettlebell, [.frontDelts, .glutes], [.triceps, .hamstrings]),
        Exercise("turkish-get-up", "Turkish get-up", .kettlebell, [.abs, .frontDelts], [.obliques, .glutes]),
        Exercise("burpee", "Burpee", .bodyweight, [.quads, .chest], [.frontDelts, .triceps, .abs], bodyweight: 0.6),
        Exercise("sled-push", "Sled push", .other, [.quads, .glutes], [.calves]),
        Exercise("wall-ball", "Wall ball", .other, [.quads, .frontDelts], [.glutes]),
    ]
}
