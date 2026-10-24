import Foundation

enum GlucoseUnit: String, Codable, CaseIterable, Identifiable {
    case mgdl = "mg/dL"
    case mmol = "mmol/L"

    var id: String { rawValue }

    private static let factor = 18.0

    // Glucose is always stored in mg/dL and converted for display.
    func fromMgdl(_ value: Double) -> Double { self == .mgdl ? value : value / Self.factor }
    func toMgdl(_ value: Double) -> Double { self == .mgdl ? value : value * Self.factor }

    func format(_ mgdl: Double) -> String {
        self == .mgdl ? String(format: "%.0f", mgdl) : String(format: "%.1f", mgdl / Self.factor)
    }
}

struct Settings: Codable, Equatable {
    var unit: GlucoseUnit = .mgdl
    var carbRatio: Double = 0          // grams of carbs covered by 1 unit
    var correctionFactor: Double = 0   // mg/dL lowered by 1 unit
    var targetMgdl: Double = 0
    var lowMgdl: Double = 70
    var highMgdl: Double = 180
    var insulinDurationHours: Double = 4
    var roundingStep: Double = 0.5
    var maxBolus: Double = 10
    var acceptedDisclaimer = false

    var isComplete: Bool { carbRatio > 0 && correctionFactor > 0 && targetMgdl > 0 }

    init() {}

    // Tolerant decoding so new settings never wipe saved data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        unit = try c.decodeIfPresent(GlucoseUnit.self, forKey: .unit) ?? d.unit
        carbRatio = try c.decodeIfPresent(Double.self, forKey: .carbRatio) ?? d.carbRatio
        correctionFactor = try c.decodeIfPresent(Double.self, forKey: .correctionFactor) ?? d.correctionFactor
        targetMgdl = try c.decodeIfPresent(Double.self, forKey: .targetMgdl) ?? d.targetMgdl
        lowMgdl = try c.decodeIfPresent(Double.self, forKey: .lowMgdl) ?? d.lowMgdl
        highMgdl = try c.decodeIfPresent(Double.self, forKey: .highMgdl) ?? d.highMgdl
        insulinDurationHours = try c.decodeIfPresent(Double.self, forKey: .insulinDurationHours) ?? d.insulinDurationHours
        roundingStep = try c.decodeIfPresent(Double.self, forKey: .roundingStep) ?? d.roundingStep
        maxBolus = try c.decodeIfPresent(Double.self, forKey: .maxBolus) ?? d.maxBolus
        acceptedDisclaimer = try c.decodeIfPresent(Bool.self, forKey: .acceptedDisclaimer) ?? d.acceptedDisclaimer
    }
}

enum InsulinKind: String, Codable, CaseIterable, Identifiable {
    case rapid = "Rapid"
    case longActing = "Long-acting"

    var id: String { rawValue }
}

struct GlucoseEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var mgdl: Double
    var note = ""
}

struct InsulinEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var units: Double
    var kind: InsulinKind
}

struct MealEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var name: String
    var carbs: Double
    var calories: Double
}

struct Food: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var carbsPer100g: Double
    var caloriesPer100g: Double

    // Average values. Labels on the actual packaging win.
    static let starters: [Food] = [
        Food(name: "White rice, cooked", carbsPer100g: 28, caloriesPer100g: 130),
        Food(name: "Pasta, cooked", carbsPer100g: 31, caloriesPer100g: 158),
        Food(name: "White bread", carbsPer100g: 49, caloriesPer100g: 265),
        Food(name: "Baguette", carbsPer100g: 56, caloriesPer100g: 270),
        Food(name: "Potatoes, boiled", carbsPer100g: 20, caloriesPer100g: 87),
        Food(name: "Apple", carbsPer100g: 14, caloriesPer100g: 52),
        Food(name: "Banana", carbsPer100g: 23, caloriesPer100g: 89),
        Food(name: "Orange juice", carbsPer100g: 10, caloriesPer100g: 45),
        Food(name: "Milk, semi-skimmed", carbsPer100g: 5, caloriesPer100g: 46),
    ]
}

enum AppTab: Hashable {
    case dose, food, log, settings
}
