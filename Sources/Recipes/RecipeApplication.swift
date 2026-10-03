import Foundation
import EditModel
import Profiles

/// One-time creative approximation, not a claim to reproduce Fujifilm's JPEG engine.
/// This table is the single editable source of all adjustment mapping coefficients.
public enum RecipeApplication {
    public enum ApplicationError: Error { case invalidSettings([RecipeWarning]), missingProfile(String), invalidWhiteBalance }
    public struct Context: Sendable {
        public var asShotTemperature: Double
        public var asShotTint: Double
        public init(asShotTemperature: Double, asShotTint: Double = 0) {
            self.asShotTemperature = asShotTemperature; self.asShotTint = asShotTint
        }
    }
    public struct Mapping: Sendable {
        public let settings: String
        public let rule: String
        fileprivate let apply: @Sendable (Recipe, Context, inout EditStack) -> Void
    }
    private static func n(_ recipe: Recipe, _ field: RecipeField) -> Double { recipe.number(field) ?? 0 }
    private static func strength(_ value: String) -> Double {
        switch Recipe.normalized(value) { case "weak": 1; case "strong": 2; default: 0 }
    }
    public static let mappingTable: [Mapping] = [
        .init(settings: "highlight_tone, shadow_tone", rule: "highlights=12×H; shadows=−12×S; shoulder=(.75,.75+.02×H), toe=(.25,.25−.02×S)") { r, _, s in
            let h = n(r, .highlightTone), shadow = n(r, .shadowTone)
            s.light.highlights = 12 * h; s.light.shadows = -12 * shadow
            s.curves.composite = h == 0 && shadow == 0 ? .identity : ToneCurve(points: [
                .init(x: 0, y: 0), .init(x: 0.25, y: 0.25 - 0.02 * shadow),
                .init(x: 0.75, y: 0.75 + 0.02 * h), .init(x: 1, y: 1)])
        },
        .init(settings: "color", rule: "saturation=8×color; vibrance=4×color") { r, _, s in
            s.color.saturation = 8 * n(r, .color); s.color.vibrance = 4 * n(r, .color)
        },
        .init(settings: "sharpness, noise_reduction", rule: "sharpenAmount=10×(sharpness+4); luminanceNR=10×(NR+4); blank leaves zero") { r, _, s in
            s.detail.sharpenAmount = r.number(.sharpness).map { 10 * ($0 + 4) } ?? 0
            s.detail.luminanceNR = r.number(.noiseReduction).map { 10 * ($0 + 4) } ?? 0
        },
        .init(settings: "grain_effect, grain_size, clarity", rule: "grain off/weak/strong=0/20/40; small/large=25/50; clarity=10×clarity") { r, _, s in
            s.effects.grainAmount = 20 * strength(r[.grainEffect])
            s.effects.grainSize = Recipe.normalized(r[.grainSize]) == "large" ? 50 : 25
            s.effects.clarity = 10 * n(r, .clarity)
        },
        .init(settings: "color_chrome_effect, color_chrome_fx_blue", rule: "CCE red/orange/yellow saturation=0/−6/−12; FX aqua/blue=0/−8/−16") { r, _, s in
            for band in [HSLColor.red, .orange, .yellow] { s.hsl[band].saturation = -6 * strength(r[.colorChromeEffect]) }
            for band in [HSLColor.aqua, .blue] { s.hsl[band].saturation = -8 * strength(r[.colorChromeFXBlue]) }
        },
        .init(settings: "wb_mode, wb_kelvin, wb_shift_r, wb_shift_b", rule: "Kelvin mode uses wb_kelvin; other modes use supplied as-shot metadata. Temperature +=150×(R−B); tint +=2×(R+B)") { r, context, s in
            // Non-Kelvin camera WB modes are already represented by as-shot metadata;
            // guessing a daylight or fluorescent illuminant would discard that measurement.
            let kelvinMode = ["kelvin", "k", "colortemperature"].contains(Recipe.normalized(r[.wbMode]))
            let base = kelvinMode ? (r.number(.wbKelvin) ?? context.asShotTemperature) : context.asShotTemperature
            s.color.temperature = min(50000, max(2000, base + 150 * (n(r, .wbShiftR) - n(r, .wbShiftB))))
            s.color.tint = min(150, max(-150, context.asShotTint + 2 * (n(r, .wbShiftR) + n(r, .wbShiftB))))
        },
        .init(settings: "dynamic_range, d_range_priority, exposure_comp", rule: "DR100/200/400 adds EV=0/1/2 and highlights=0/−20/−40; DR-P weak/strong/auto uses 1/2/1 stops; add exposure_comp") { r, _, s in
            let dr = Recipe.normalized(r[.dynamicRange])
            var stops: Double = ["dr400", "400"].contains(dr) ? 2 : (["dr200", "200"].contains(dr) ? 1 : 0)
            let priority = Recipe.normalized(r[.dRangePriority])
            if priority == "weak" || priority == "auto" { stops = 1 }
            if priority == "strong" { stops = 2 }
            // Auto uses a fixed middle approximation because recipes never inspect pixels.
            s.light.exposure = min(5, max(-5, stops + n(r, .exposureComp)))
            s.light.highlights -= 20 * stops
        }
    ]

    /// Reapplying replaces only mapped controls, so unrelated edits do not mark a recipe modified.
    public static func isModified(_ recipe: Recipe, stack: EditStack, profiles: ProfileLibrary,
                                  context: Context, cameraModel: String = "FUJIFILM X-T5") throws -> Bool {
        try apply(recipe, to: stack, profiles: profiles, context: context, cameraModel: cameraModel) != stack
    }

    /// Resolve at selection time. RenderPipeline never imports Recipes or reads recipeID.
    /// Existing geometry, optics and unrelated edits survive; mapped controls are replaced
    /// so reapplying a preset cannot accumulate adjustments.
    public static func apply(_ recipe: Recipe, to stack: EditStack, profiles: ProfileLibrary,
                             context: Context, cameraModel: String = "FUJIFILM X-T5",
                             allowUnresolvedSimulation: Bool = false) throws -> EditStack {
        let warnings = recipe.validationWarnings()
        guard warnings.isEmpty else { throw ApplicationError.invalidSettings(warnings) }
        guard context.asShotTemperature.isFinite, context.asShotTemperature > 0, context.asShotTint.isFinite else {
            throw ApplicationError.invalidWhiteBalance
        }
        let simulation = Recipe.simulationKey(recipe[.filmSimulation])
        let profile = profiles.profiles(for: cameraModel).first(where: {
            Recipe.simulationKey($0.displayName) == simulation || Recipe.simulationKey($0.displayName.replacingOccurrences(of: "Camera ", with: "")) == simulation
        })
        guard profile != nil || allowUnresolvedSimulation else {
            throw ApplicationError.missingProfile(recipe[.filmSimulation])
        }
        // A missing calibration is explicit; never manufacture a creative LUT as a profile.
        var result = stack
        // The camera panel can retain an unavailable simulation as intent, with an explicit
        // preview notice. Clear an old film look so it cannot masquerade as the new selection.
        result.profileID = profile?.identifier ?? ""
        for mapping in mappingTable { mapping.apply(recipe, context, &result) }
        result.recipeID = recipe.id
        return result
    }
}
