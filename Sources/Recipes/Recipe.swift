import Foundation

/// PROPOSAL: this schema and the creative mapping are adjustable, not a camera calibration.
public enum RecipeField: String, CaseIterable, Sendable {
    case recipeID = "recipe_id", name, filmSimulation = "film_simulation", wbMode = "wb_mode"
    case wbKelvin = "wb_kelvin", wbShiftR = "wb_shift_r", wbShiftB = "wb_shift_b"
    case dynamicRange = "dynamic_range", dRangePriority = "d_range_priority"
    case highlightTone = "highlight_tone", shadowTone = "shadow_tone", color, sharpness
    case noiseReduction = "noise_reduction", clarity, colorChromeEffect = "color_chrome_effect"
    case colorChromeFXBlue = "color_chrome_fx_blue", grainEffect = "grain_effect", grainSize = "grain_size"
    case exposureComp = "exposure_comp", isoRange = "iso_range", example1 = "example_1"
    case example2 = "example_2", example3 = "example_3", exampleExtra = "example_extra"
    case tags, notes, source, created, modified, revision
    case used, liked, sourceSheet = "source_sheet", importNotes = "import_notes"
    case monochromaticColorWC = "monochromatic_color_wc", monochromaticColorMG = "monochromatic_color_mg"
}

public struct RecipeWarning: Equatable, Sendable {
    public let row: Int
    public let field: String
    public let message: String
    public init(row: Int, field: String, message: String) {
        self.row = row; self.field = field; self.message = message
    }
}

public struct Recipe: Equatable, Sendable, Identifiable {
    // Raw text remains available even when conversion fails, so editing never silently loses data.
    public var fields: [RecipeField: String]
    public var row: Int
    public var warnings: [RecipeWarning] = []
    public var id: String { self[.recipeID] }
    public var name: String { self[.name] }
    public init(fields: [RecipeField: String], row: Int = 0) { self.fields = fields; self.row = row }
    public subscript(_ field: RecipeField) -> String {
        get { fields[field] ?? "" }
        set { fields[field] = newValue }
    }
    public func number(_ field: RecipeField) -> Double? {
        guard let value = Double(self[field].trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        return value
    }
    public static let filmSimulations = ["Provia/Standard", "Velvia", "Astia", "Classic Chrome", "PRO Neg. Hi",
        "PRO Neg. Std", "Reala ACE", "Classic Neg", "Nostalgic Neg", "Eterna", "Eterna Bleach Bypass", "Acros",
        "Acros +Ye", "Acros +R", "Acros +G", "Monochrome", "Monochrome +Ye", "Monochrome +R", "Monochrome +G", "Sepia"]
    public static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" }
    }
    public static func simulationKey(_ text: String) -> String {
        let key = normalized(text)
        return ["provia", "standard", "proviastandard"].contains(key) ? "proviastandard" : key
    }
    // The form and validator share these limits so accepted camera settings cannot drift.
    public static let numericConstraints: [(RecipeField, ClosedRange<Double>, Double)] = [
            (.highlightTone, -2...4, 0.5), (.shadowTone, -2...4, 0.5), (.color, -4...4, 1),
            (.sharpness, -4...4, 1), (.noiseReduction, -4...4, 1), (.clarity, -5...5, 1),
            (.monochromaticColorWC, -18...18, 1), (.monochromaticColorMG, -18...18, 1),
            (.wbShiftR, -9...9, 1), (.wbShiftB, -9...9, 1), (.wbKelvin, 2500...10000, 1)]
    public static let choiceConstraints: [(RecipeField, [String])] = [(.grainEffect, ["off", "weak", "strong"]),
            (.grainSize, ["small", "large"]), (.colorChromeEffect, ["off", "weak", "strong"]),
            (.colorChromeFXBlue, ["off", "weak", "strong"]), (.dynamicRange, ["DR100", "DR200", "DR400", "100", "200", "400", "Auto"]),
            (.dRangePriority, ["off", "weak", "strong", "auto"])]
    public func validationWarnings() -> [RecipeWarning] {
        var result: [RecipeWarning] = []
        func warn(_ field: RecipeField, _ message: String) {
            result.append(.init(row: row, field: field.rawValue, message: message))
        }
        for field in [RecipeField.recipeID, .name] where self[field].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warn(field, "Required value is blank")
        }
        if Self.normalized(self[.filmSimulation]) != "realaace" && !Self.filmSimulations.contains(where: { Self.simulationKey($0) == Self.simulationKey(self[.filmSimulation]) }) {
            warn(.filmSimulation, "Unknown X-T5 film simulation")
        }
        for (field, range, step) in Self.numericConstraints where !self[field].isEmpty {
            guard let n = number(field), range.contains(n), abs(n / step - (n / step).rounded()) < 1e-8 else {
                warn(field, "Expected \(range) in steps of \(step); got \(self[field])"); continue
            }
        }
        if ["kelvin", "k", "colortemperature"].contains(Self.normalized(self[.wbMode])) && self[.wbKelvin].isEmpty {
            warn(.wbKelvin, "Kelvin WB mode requires a temperature")
        }
        if !self[.exposureComp].isEmpty && number(.exposureComp) == nil { warn(.exposureComp, "Expected a finite EV number") }
        for (field, allowed) in Self.choiceConstraints where !self[field].isEmpty {
            if !allowed.map(Self.normalized).contains(Self.normalized(self[field])) { warn(field, "Expected \(allowed.joined(separator: "/"))") }
        }
        return result
    }
    public static let exampleFields: [RecipeField] = [.example1, .example2, .example3, .exampleExtra]
}
