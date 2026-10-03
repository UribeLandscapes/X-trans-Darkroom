import Foundation
import CoreImage
import EditModel

/// Build plan §4: the eight-band HSL mixer and colour grading, applied as a single 3D LUT.
///
/// Core Image has no per-band HSL filter and the Metal offline compiler is unavailable on
/// this machine, so a custom kernel is not an option. A colour cube is: build the LUT on the
/// CPU whenever the parameters change, then let the GPU apply it in one pass at any
/// resolution. Rebuilds are cached by parameter hash, so a slider drag rebuilds once per
/// value change (~1 ms at 17³) and every render in between is a free texture lookup.
public final class ColorCubeCache: @unchecked Sendable {

    /// 17 per axis: 4913 entries. Large enough that banding is invisible after the GPU's
    /// trilinear interpolation, small enough to rebuild inside a frame.
    private let dimension = 17

    private var cachedKey: Int?
    private var cachedData: Data?

    public init() {}

    public func cube(for mix: HSLMix, grading: ColorGrading) -> Data? {
        guard !mix.isNeutral || !grading.isNeutral else { return nil }

        var hasher = Hasher()
        for color in HSLColor.allCases {
            let b = mix[color]
            hasher.combine(b.hue); hasher.combine(b.saturation); hasher.combine(b.luminance)
        }
        hasher.combine(grading.shadowHue); hasher.combine(grading.shadowSaturation)
        hasher.combine(grading.midtoneHue); hasher.combine(grading.midtoneSaturation)
        hasher.combine(grading.highlightHue); hasher.combine(grading.highlightSaturation)
        hasher.combine(grading.blending); hasher.combine(grading.balance)
        let key = hasher.finalize()

        if key == cachedKey, let cachedData { return cachedData }

        let data = Self.build(mix: mix, grading: grading, dimension: dimension)
        cachedKey = key
        cachedData = data
        return data
    }

    public static func build(mix: HSLMix, grading: ColorGrading, dimension n: Int) -> Data {
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            let b = Double(bi) / Double(n - 1)
            for gi in 0..<n {
                let g = Double(gi) / Double(n - 1)
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1)
                    var (rr, gg, bb) = (r, g, b)
                    (rr, gg, bb) = applyHSL(rr, gg, bb, mix)
                    (rr, gg, bb) = applyGrading(rr, gg, bb, grading)
                    values[i + 0] = Float(min(max(rr, 0), 1))
                    values[i + 1] = Float(min(max(gg, 0), 1))
                    values[i + 2] = Float(min(max(bb, 0), 1))
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Each band influences a pixel by how close its hue is to the band centre, falling off
    /// smoothly so adjacent bands blend instead of producing hard edges in gradients.
    static func applyHSL(_ r: Double, _ g: Double, _ b: Double, _ mix: HSLMix) -> (Double, Double, Double) {
        guard !mix.isNeutral else { return (r, g, b) }
        var (h, s, v) = HSV.fromRGB(r, g, b)
        guard s > 1e-6 else { return (r, g, b) }   // Neutrals carry no hue to shift.

        var hueShift = 0.0, satScale = 1.0, lumScale = 1.0
        let falloff = 45.0   // degrees; roughly the half-distance between adjacent bands

        for color in HSLColor.allCases {
            let band = mix[color]
            guard !band.isNeutral else { continue }
            let distance = HSV.hueDistance(h, color.centerHue)
            guard distance < falloff else { continue }
            // Smoothstep weight: 1 at the band centre, 0 at the falloff edge.
            let t = 1 - distance / falloff
            let w = t * t * (3 - 2 * t)
            hueShift += band.hue * 0.3 * w
            satScale *= 1 + band.saturation / 100 * w
            lumScale *= 1 + band.luminance / 100 * w
        }

        h = (h + hueShift).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        s = min(max(s * satScale, 0), 1)
        v = min(max(v * lumScale, 0), 1)
        return HSV.toRGB(h, s, v)
    }

    /// Luminance-weighted tinting of three zones. `balance` slides the midpoint; `blending`
    /// widens or narrows the overlap between zones.
    static func applyGrading(_ r: Double, _ g: Double, _ b: Double, _ grading: ColorGrading) -> (Double, Double, Double) {
        guard !grading.isNeutral else { return (r, g, b) }
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let balance = grading.balance / 100 * 0.3
        let width = 0.25 + grading.blending / 100 * 0.35

        func weight(center: Double) -> Double {
            let d = abs(luma - (center + balance)) / width
            return d >= 1 ? 0 : (1 - d) * (1 - d)
        }

        var (rr, gg, bb) = (r, g, b)
        func tint(hue: Double, saturation: Double, weight w: Double) {
            guard saturation != 0, w > 0 else { return }
            let (tr, tg, tb) = HSV.toRGB(hue, 1, 1)
            let amount = saturation / 100 * w * 0.5
            rr += (tr - 0.5) * amount
            gg += (tg - 0.5) * amount
            bb += (tb - 0.5) * amount
        }
        tint(hue: grading.shadowHue, saturation: grading.shadowSaturation, weight: weight(center: 0.15))
        tint(hue: grading.midtoneHue, saturation: grading.midtoneSaturation, weight: weight(center: 0.5))
        tint(hue: grading.highlightHue, saturation: grading.highlightSaturation, weight: weight(center: 0.85))
        return (rr, gg, bb)
    }
}
