import Foundation
import ImagingCore

/// Build plan §2: one immutable value type holds every adjustment for one image.
///
/// - Order independent: the pipeline order is fixed in the renderer, not in this struct.
/// - Every field has a documented neutral default, so omitted keys round-trip cleanly
///   and adding a field in a later version does not invalidate existing sidecars.
/// - Editing produces a new value. Undo/redo is an array of these, not a command log.
public struct EditStack: Codable, Equatable, Sendable {

    /// Schema version. Bump when a field's *meaning* changes, never for additions.
    public var version: Int = 1

    /// Identifies the source file this stack belongs to (see `SourceFingerprint`).
    public var fingerprint: String = ""

    public var light: LightAdjustments = .neutral
    public var curves: ToneCurveSet = .neutral
    public var color: ColorAdjustments = .neutral
    public var hsl: HSLMix = .neutral
    public var grading: ColorGrading = .neutral

    // Phases 3-5 fill these in. Declared now so sidecars written today stay readable.
    public var effects: EffectsAdjustments = .neutral
    public var detail: DetailAdjustments = .neutral
    public var optics: OpticsAdjustments = .neutral
    public var geometry: GeometryAdjustments = .neutral
    public var custom: CustomAdjustments = .neutral

    /// Selected camera profile identifier (Build plan §4). Empty = the file's default.
    public var profileID: String = ""

    /// Recipe this stack was seeded from (Build plan §5). Empty = none.
    /// A recipe resolves into the fields above at apply time; it is not a render stage.
    public var recipeID: String = ""

    /// Persist the camera vocabulary with its resolved edits so undo and reopening agree.
    public var cameraSettings: [String: String]?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, fingerprint, light, curves, color, hsl, grading, effects, detail, optics, geometry, custom, profileID, recipeID, cameraSettings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version     = try c.value(.version, 1)
        fingerprint = try c.value(.fingerprint, "")
        light    = (try c.decodeIfPresent(LightAdjustments.self,    forKey: .light)) ?? .neutral
        curves   = (try c.decodeIfPresent(ToneCurveSet.self,        forKey: .curves)) ?? .neutral
        color    = (try c.decodeIfPresent(ColorAdjustments.self,    forKey: .color)) ?? .neutral
        hsl      = (try c.decodeIfPresent(HSLMix.self,              forKey: .hsl)) ?? .neutral
        grading  = (try c.decodeIfPresent(ColorGrading.self,        forKey: .grading)) ?? .neutral
        effects  = (try c.decodeIfPresent(EffectsAdjustments.self,  forKey: .effects)) ?? .neutral
        detail   = (try c.decodeIfPresent(DetailAdjustments.self,   forKey: .detail)) ?? .neutral
        optics   = (try c.decodeIfPresent(OpticsAdjustments.self,   forKey: .optics)) ?? .neutral
        geometry = (try c.decodeIfPresent(GeometryAdjustments.self, forKey: .geometry)) ?? .neutral
        custom = (try c.decodeIfPresent(CustomAdjustments.self, forKey: .custom)) ?? .neutral
        profileID = try c.value(.profileID, "")
        recipeID  = try c.value(.recipeID, "")
        cameraSettings = try c.decodeIfPresent([String: String].self, forKey: .cameraSettings)
    }

    /// True when nothing has been changed from neutral - drives the "edited" badge in the grid.
    public var isNeutral: Bool {
        light == .neutral && curves.isNeutral && color == .neutral
            && hsl.isNeutral && grading.isNeutral && geometry.isNeutral && effects == .neutral
            && custom == .neutral && detail == .neutral && optics == .neutral && geometry == .neutral
            && profileID.isEmpty && recipeID.isEmpty
    }
}

// MARK: - Light

public struct LightAdjustments: Codable, Equatable, Sendable {
    public var exposure: Double = 0      // EV, -5...+5
    public var contrast: Double = 0      // -100...+100
    public var highlights: Double = 0    // -100...+100
    public var shadows: Double = 0       // -100...+100
    public var whites: Double = 0        // -100...+100
    public var blacks: Double = 0        // -100...+100

    public static let neutral = LightAdjustments()
    public init() {}

    private enum CodingKeys: String, CodingKey { case exposure, contrast, highlights, shadows, whites, blacks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.value(.exposure, 0)
        contrast = try c.value(.contrast, 0)
        highlights = try c.value(.highlights, 0)
        shadows = try c.value(.shadows, 0)
        whites = try c.value(.whites, 0)
        blacks = try c.value(.blacks, 0)
    }

    public static let parameters: [Parameter] = [
        Parameter(key: "exposure",   range: -5...5,       neutral: 0),
        Parameter(key: "contrast",   range: -100...100,   neutral: 0),
        Parameter(key: "highlights", range: -100...100,   neutral: 0),
        Parameter(key: "shadows",    range: -100...100,   neutral: 0),
        Parameter(key: "whites",     range: -100...100,   neutral: 0),
        Parameter(key: "blacks",     range: -100...100,   neutral: 0),
    ]
}

// MARK: - Color

public struct ColorAdjustments: Codable, Equatable, Sendable {
    /// Kelvin. 0 means "as shot" - resolved from file metadata at decode time.
    public var temperature: Double = 0
    public var tint: Double = 0          // -150...+150, green/magenta
    public var blackAndWhite: Bool = false
    public var vibrance: Double = 0      // -100...+100
    public var saturation: Double = 0    // -100...+100

    public static let neutral = ColorAdjustments()
    public init() {}

    private enum CodingKeys: String, CodingKey { case temperature, tint, vibrance, saturation, blackAndWhite }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blackAndWhite = try c.value(.blackAndWhite, false)
        temperature = try c.value(.temperature, 0)
        tint = try c.value(.tint, 0)
        vibrance = try c.value(.vibrance, 0)
        saturation = try c.value(.saturation, 0)
    }

    public static let parameters: [Parameter] = [
        Parameter(key: "temperature", range: 2000...50000, neutral: 0),
        Parameter(key: "tint",        range: -150...150,   neutral: 0),
        Parameter(key: "vibrance",    range: -100...100,   neutral: 0),
        Parameter(key: "saturation",  range: -100...100,   neutral: 0),
    ]
}

// MARK: - Placeholders for later phases (fields only, no pipeline yet)

public struct EffectsAdjustments: Codable, Equatable, Sendable {
    public var texture: Double = 0
    public var clarity: Double = 0
    public var dehaze: Double = 0
    public var grainAmount: Double = 0
    /// Pixel domain: grain size must scale with the proxy ratio (§2).
    public var grainSize: Double = 25
    public var vignetteAmount: Double = 0
    public static let neutral = EffectsAdjustments()
    public init() {}

    private enum CodingKeys: String, CodingKey { case texture, clarity, dehaze, grainAmount, grainSize, vignetteAmount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        texture = try c.value(.texture, 0)
        clarity = try c.value(.clarity, 0)
        dehaze = try c.value(.dehaze, 0)
        grainAmount = try c.value(.grainAmount, 0)
        grainSize = try c.value(.grainSize, 25)
        vignetteAmount = try c.value(.vignetteAmount, 0)
    }
}

public struct DetailAdjustments: Codable, Equatable, Sendable {
    public var sharpenAmount: Double = 0
    /// Pixel domain.
    public var sharpenRadius: Double = 1.0
    public var luminanceNR: Double = 0
    /// 0, not Lightroom's 25. Lightroom applies colour NR by default to RAW only, and
    /// baking that into the neutral stack would mean "no adjustments" is not an identity -
    /// which quietly invalidates every fidelity measurement in the project. The RAW open
    /// path seeds 25 for RAW files instead (see EditorModel.open).
    public var colorNR: Double = 0
    public static let neutral = DetailAdjustments()
    public init() {}

    private enum CodingKeys: String, CodingKey { case sharpenAmount, sharpenRadius, luminanceNR, colorNR }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharpenAmount = try c.value(.sharpenAmount, 0)
        sharpenRadius = try c.value(.sharpenRadius, 1.0)
        luminanceNR = try c.value(.luminanceNR, 0)
        colorNR = try c.value(.colorNR, 0)
    }
}

public struct OpticsAdjustments: Codable, Equatable, Sendable {
    // Decode treatment, not a pipeline stage: neutral rendered input remains identity.
    public var builtInLensCorrection = true
    public var correctDistortion: Bool = true
    public var correctVignetting: Bool = true
    public var removeChromaticAberration: Bool = true
    /// Which source supplied the profile - shown in the Optics panel (§6).
    public var profileSource: String = ""
    public static let neutral = OpticsAdjustments()
    public init() {}

    private enum CodingKeys: String, CodingKey { case builtInLensCorrection, correctDistortion, correctVignetting, removeChromaticAberration, profileSource }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        builtInLensCorrection = try c.value(.builtInLensCorrection, true)
        correctDistortion = try c.value(.correctDistortion, true)
        correctVignetting = try c.value(.correctVignetting, true)
        removeChromaticAberration = try c.value(.removeChromaticAberration, true)
        profileSource = try c.value(.profileSource, "")
    }
}

public struct GeometryAdjustments: Codable, Equatable, Sendable {
    /// Degrees, positive = counter-clockwise. Applied about the frame centre.
    public var straightenAngle: Double = 0
    /// Quarter turns applied before straightening: 0-3.
    public var rotation: Int = 0
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false

    /// Perspective transform, all in normalized units so they survive the proxy (§2).
    public var perspectiveVertical: Double = 0
    public var perspectiveHorizontal: Double = 0
    public var transformScale: Double = 1

    /// Normalized crop rect in unit coordinates of the *straightened* frame. Full = 0,0,1,1.
    public var cropX: Double = 0
    public var cropY: Double = 0
    public var cropWidth: Double = 1
    public var cropHeight: Double = 1

    public static let neutral = GeometryAdjustments()
    public init() {}

    public var isNeutral: Bool { self == .neutral }

    public var hasCrop: Bool {
        cropX != 0 || cropY != 0 || cropWidth != 1 || cropHeight != 1
    }

    /// Largest centred rectangle of the original aspect that fits inside a frame
    /// rotated by `straightenAngle` — this is what stops a straighten from exposing
    /// transparent wedges at the corners.
    public static func autoCropScale(angleDegrees: Double, aspect: Double) -> Double {
        let a = abs(angleDegrees) * .pi / 180
        guard a > 1e-9 else { return 1 }
        let w = aspect, h = 1.0
        let cosA = cos(a), sinA = sin(a)
        // Fixed-aspect containment: scale the crop until each corner touches the rotated frame.
        return min(w / (w * cosA + h * sinA), h / (w * sinA + h * cosA))
    }

    private enum CodingKeys: String, CodingKey {
        case straightenAngle, rotation, flipHorizontal, flipVertical
        case perspectiveVertical, perspectiveHorizontal, transformScale
        case cropX, cropY, cropWidth, cropHeight
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        straightenAngle = try c.value(.straightenAngle, 0)
        rotation = try c.value(.rotation, 0)
        flipHorizontal = try c.value(.flipHorizontal, false)
        flipVertical = try c.value(.flipVertical, false)
        perspectiveVertical = try c.value(.perspectiveVertical, 0)
        perspectiveHorizontal = try c.value(.perspectiveHorizontal, 0)
        transformScale = try c.value(.transformScale, 1)
        cropX = try c.value(.cropX, 0)
        cropY = try c.value(.cropY, 0)
        cropWidth = try c.value(.cropWidth, 1)
        cropHeight = try c.value(.cropHeight, 1)
    }
}
