import Foundation

struct BolusResult {
    var carbDose: Double
    var correction: Double
    var iobUsed: Double
    var raw: Double
    var rounded: Double
    var isLow: Bool
    var warnings: [String]
}

enum BolusCalculator {
    /// Standard bolus formula: carbs / carb ratio + (glucose - target) / correction factor.
    /// Insulin on board only reduces a positive correction, never the carb dose.
    /// The total is rounded down so rounding never adds insulin.
    static func calculate(carbs: Double, bgMgdl: Double?, iob: Double, settings: Settings) -> BolusResult {
        let carbDose = carbs / settings.carbRatio

        var correction = 0.0
        if let bg = bgMgdl {
            correction = (bg - settings.targetMgdl) / settings.correctionFactor
        }

        var iobUsed = 0.0
        var adjusted = correction
        if correction > 0 {
            iobUsed = min(iob, correction)
            adjusted = correction - iobUsed
        }

        let raw = max(0, carbDose + adjusted)
        let step = settings.roundingStep > 0 ? settings.roundingStep : 0.5
        let rounded = ((raw + 1e-9) / step).rounded(.down) * step

        let isLow = bgMgdl.map { $0 < settings.lowMgdl } ?? false
        var warnings: [String] = []
        if bgMgdl == nil {
            warnings.append("No glucose entered, so no correction is included.")
        }
        if let bg = bgMgdl, bg >= 250 {
            warnings.append("Glucose is high. Check ketones and follow your sick-day plan if they're raised.")
        }
        if rounded > settings.maxBolus {
            warnings.append("This is above your max single dose. Double-check carbs and glucose.")
        }
        if iob > 0, correction <= 0 {
            warnings.append("You still have insulin on board. Watch for a low.")
        }

        return BolusResult(
            carbDose: carbDose,
            correction: correction,
            iobUsed: iobUsed,
            raw: raw,
            rounded: rounded,
            isLow: isLow,
            warnings: warnings
        )
    }
}
