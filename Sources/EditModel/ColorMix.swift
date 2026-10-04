import Foundation

/// Build plan §4 (Color tab): the eight-band HSL mixer and three-way colour grading.
/// Both are global operations — no masks, no local adjustments.

public struct HSLBand: Codable, Equatable, Sendable {
    public var hue: Double = 0          // -100...+100, shifts within the band
    public var saturation: Double = 0   // -100...+100
    public var luminance: Double = 0    // -100...+100
    public init() {}
    public var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    private enum CodingKeys: String, CodingKey { case hue, saturation, luminance }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.value(.hue, 0); saturation = try c.value(.saturation, 0); luminance = try c.value(.luminance, 0)
    }
}

/// The eight bands Lightroom uses, with their centre hues in degrees.
public enum HSLColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var centerHue: Double {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 60
        case .green: return 120
        case .aqua: return 180
        case .blue: return 240
        case .purple: return 280
        case .magenta: return 320
        }
    }
}

public struct HSLMix: Codable, Equatable, Sendable {
    public var bands: [String: HSLBand] = [:]
    public static let neutral = HSLMix()
    public init() {}

    public subscript(color: HSLColor) -> HSLBand {
        get { bands[color.rawValue] ?? HSLBand() }
        set { bands[color.rawValue] = newValue }
    }

    public var isNeutral: Bool { bands.values.allSatisfy(\.isNeutral) }

    private enum CodingKeys: String, CodingKey { case bands }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bands = (try c.decodeIfPresent([String: HSLBand].self, forKey: .bands)) ?? [:]
    }
}

/// Three-way colour grading. Each zone tints by hue/saturation; `blending` sets how much the
/// zones overlap and `balance` slides the midpoint between shadows and highlights.
public struct ColorGrading: Codable, Equatable, Sendable {
    public var shadowHue: Double = 0
    public var shadowSaturation: Double = 0
    public var midtoneHue: Double = 0
    public var midtoneSaturation: Double = 0
    public var highlightHue: Double = 0
    public var highlightSaturation: Double = 0
    public var blending: Double = 50
    public var balance: Double = 0

    public static let neutral = ColorGrading()
    public init() {}

    public var isNeutral: Bool {
        shadowSaturation == 0 && midtoneSaturation == 0 && highlightSaturation == 0
    }

    private enum CodingKeys: String, CodingKey {
        case shadowHue, shadowSaturation, midtoneHue, midtoneSaturation
        case highlightHue, highlightSaturation, blending, balance
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadowHue = try c.value(.shadowHue, 0); shadowSaturation = try c.value(.shadowSaturation, 0)
        midtoneHue = try c.value(.midtoneHue, 0); midtoneSaturation = try c.value(.midtoneSaturation, 0)
        highlightHue = try c.value(.highlightHue, 0); highlightSaturation = try c.value(.highlightSaturation, 0)
        blending = try c.value(.blending, 50); balance = try c.value(.balance, 0)
    }
}

/// Shared HSV helpers. Used by the colour-cube builder and by the checks, so the two cannot
/// disagree about what a hue rotation means.
public enum HSV {
    public static func fromRGB(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        var h = 0.0
        if delta > 1e-9 {
            if maxV == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if maxV == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
        }
        if h < 0 { h += 360 }
        return (h, maxV <= 1e-9 ? 0 : delta / maxV, maxV)
    }

    public static func toRGB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s
        let hh = h.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hh) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = v - c
        return (r1 + m, g1 + m, b1 + m)
    }

    /// Shortest angular distance between two hues, in degrees (0...180).
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}
