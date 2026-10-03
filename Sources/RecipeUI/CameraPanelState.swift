import Foundation
import RawDecode
import Recipes
import EditModel
import Profiles

/// A value snapshot: Editor stores it in EditStack, making camera and manual edits share history.
public struct CameraPanelState: Sendable, Equatable {
    public let asShot: [String: String]
    public private(set) var values: [String: String]
    public static let fields: [RecipeField] = [.filmSimulation, .monochromaticColorWC, .monochromaticColorMG,
        .grainEffect, .grainSize, .colorChromeEffect, .colorChromeFXBlue, .wbMode, .wbKelvin, .wbShiftR, .wbShiftB,
        .dynamicRange, .highlightTone, .shadowTone, .color, .sharpness, .noiseReduction, .clarity,
        .dRangePriority, .exposureComp]
    public static let whiteBalanceModes = ["Auto", "Auto (white priority)", "Auto (ambiance priority)",
        "Daylight", "Cloudy", "Daylight Fluorescent", "Day White Fluorescent", "White Fluorescent",
        "Incandescent", "Underwater", "Custom", "Custom2", "Custom3", "Kelvin"]

    public init(asShot: AsShotSettings?, saved: [String: String]? = nil) {
        self.asShot = asShot?.values ?? [:]
        values = saved ?? self.asShot
    }
    public subscript(_ field: RecipeField) -> String { values[field.rawValue] ?? "" }
    public var monochrome: Bool {
        let key = Recipe.normalized(self[.filmSimulation])
        return key.hasPrefix("acros") || key.hasPrefix("monochrome")
    }
    public func differs(_ field: RecipeField) -> Bool {
        let a = self[field], b = asShot[field.rawValue] ?? ""
        if let x = Double(a), let y = Double(b) { return x != y }
        if field == .filmSimulation { return Recipe.simulationKey(a) != Recipe.simulationKey(b) }
        if field == .dynamicRange { return Recipe.normalized(a).replacingOccurrences(of: "dr", with: "") != Recipe.normalized(b).replacingOccurrences(of: "dr", with: "") }
        return Recipe.normalized(a) != Recipe.normalized(b)
    }
    public var differences: Set<RecipeField> { Set(Self.fields.filter { differs($0) }) }
    public mutating func resetToShotSettings() { values = asShot }

    public static func choices(for field: RecipeField) -> [String]? {
        if field == .filmSimulation { return Recipe.filmSimulations }
        if field == .wbMode { return whiteBalanceModes }
        if field == .dynamicRange { return ["100", "200", "400", "Auto"] }
        return Recipe.choiceConstraints.first { $0.0 == field }?.1.map { $0.capitalized }
    }
    public static func accepts(_ text: String, for field: RecipeField) -> Bool {
        if let (_, range, step) = Recipe.numericConstraints.first(where: { $0.0 == field }) {
            guard let n = Double(text), n.isFinite else { return false }
            return range.contains(n) && abs(n / step - (n / step).rounded()) < 1e-8
        }
        if let choices = choices(for: field) {
            return choices.contains { field == .filmSimulation ? Recipe.simulationKey($0) == Recipe.simulationKey(text) : Recipe.normalized($0) == Recipe.normalized(text) }
        }
        return field == .exposureComp && Double(text)?.isFinite == true
    }
    @discardableResult public mutating func set(_ field: RecipeField, to text: String) -> Bool {
        guard Self.accepts(text, for: field) else { return false }
        values[field.rawValue] = text
        return true
    }
    public mutating func apply(_ recipe: Recipe) throws {
        let warnings = recipe.validationWarnings()
        guard warnings.isEmpty else { throw RecipeApplication.ApplicationError.invalidSettings(warnings) }
        // Blank recipe cells retain the shot value, so partial recipes have a visible baseline.
        values = asShot
        for field in Self.fields where !recipe[field].isEmpty {
            values[field.rawValue] = recipe[field]
        }
    }
    public func resolved(on stack: EditStack, profiles: ProfileLibrary, context: RecipeApplication.Context,
                         cameraModel: String, recipeID: String? = nil,
                         allowUnresolvedSimulation: Bool = false) throws -> EditStack {
        let identifier = recipeID ?? stack.recipeID
        var fields: [RecipeField: String] = [.recipeID: identifier.isEmpty ? "camera-settings" : identifier, .name: "Camera settings"]
        for field in Self.fields { fields[field] = values[field.rawValue] }
        var result = try RecipeApplication.apply(Recipe(fields: fields), to: stack, profiles: profiles,
                                                 context: context, cameraModel: cameraModel, allowUnresolvedSimulation: allowUnresolvedSimulation)
        result.recipeID = recipeID ?? stack.recipeID
        result.cameraSettings = values
        return result
    }
}
