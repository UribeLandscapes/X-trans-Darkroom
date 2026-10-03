import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImagingCore
import EditModel
import RawDecode
import Profiles

/// Build plan §2: one ordered pipeline, expressed once, instantiated at two scales.
///
/// Pixel output is a pure function of (frame, stack, proxyRatio); caches only reuse data,
/// so the interactive and settle renders cannot drift apart - they run identical code with
/// a different `proxyRatio`, which is exactly what makes the proxy trustworthy.
///
/// The executable stage sequence preserves the build plan order at both scales.
/// Filter outputs are cropped to their stage's input extent because colour operations can
/// create values outside the source and spatial filters can expand their support. Keeping
/// those bounds finite preserves canvas drawing and full-extent readback. Only geometry's
/// deliberate crop, straighten and orientation operations change the frame dimensions.
public struct RenderPipeline: Sendable {

    /// An 18% grey card in scene-linear light - the pivot photographic contrast turns about.
    static let middleGreyLinear = 0.18

    /// Radii in full-resolution pixels. Texture acts on fine detail, clarity on mid-frequency
    /// structure; the gap between them is what makes the two controls feel different.
    static let textureRadius = 1.5
    static let clarityRadius = 12.0

    /// Shared across renders: the cube only rebuilds when HSL or grading values change,
    /// so the interactive path pays for it once per slider value, not once per frame.
    private static let cubeCache = ColorCubeCache()

    /// Shared so kernel compilation and the gain map cache survive between frames.
    private static let lensCorrectionFilter = LensCorrectionFilter()

    public enum Stage: Sendable { case whiteBalance, profile, optics, light, effects, color, colorMix, curves, detail, grainAndVignette, glow, geometry }
    public static let stages: [Stage] = [.whiteBalance, .profile, .optics, .light, .effects, .color, .colorMix, .curves, .detail, .grainAndVignette, .glow, .geometry]
    private let profileCubeCache: ProfileCubeCache
    public init(profileCubeCache: ProfileCubeCache = ProfileCubeCache()) {
        self.profileCubeCache = profileCubeCache
    }

    func applyProfile(_ image: CIImage, profile: CameraProfile?, kelvin: Double) -> CIImage {
        guard let profile else { return image }
        var out = image
        // Forward matrices take precedence; applying both would apply calibration twice.
        if let matrix = profile.forwardMatrix(whiteBalanceKelvin: kelvin)
            ?? profile.colorMatrix(whiteBalanceKelvin: kelvin), matrix != .identity {
            let m = matrix.elements
            let f = CIFilter.colorMatrix()
            f.inputImage = out
            f.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
            f.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
            f.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }
        func cube(_ kind: ProfileCubeCache.Kind, _ image: CIImage) -> CIImage {
            guard let data = profileCubeCache.cube(for: profile, kind: kind, kelvin: kelvin) else { return image }
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = image
            f.cubeDimension = Float(ProfileCubeCache.dimension)
            f.cubeData = data
            f.colorSpace = WorkingColorSpace.linearWide
            return (f.outputImage ?? image).cropped(to: image.extent)
        }
        out = cube(.hueSat, out)
        if let curve = profile.profileToneCurve, !curve.isIdentity {
            let data = curve.lut().flatMap { [$0, $0, $0] }
            let f = CIFilter.colorCurves()
            f.inputImage = out
            f.curvesData = data.withUnsafeBufferPointer { Data(buffer: $0) }
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = WorkingColorSpace.linearWide
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }
        return cube(.look, out)
    }

    public func render(_ frame: DecodedFrameInput, stack: EditStack, proxyRatio: Double) -> CIImage {
        var image = frame.image

        for stage in Self.stages {
            switch stage {
            case .whiteBalance: image = applyWhiteBalance(image, stack.color, asShot: frame.asShotTemperature)
            case .profile:
                image = applyProfile(image, profile: frame.profile,
                                     kelvin: stack.color.temperature == 0 ? frame.asShotTemperature : stack.color.temperature)
            case .optics: image = applyOptics(image, stack.optics, correction: frame.lensCorrection)
            case .light: image = applyLight(image, stack.light)
            case .effects: image = applyEffects(image, stack.effects, proxyRatio: proxyRatio)
            case .color: image = applyColor(image, stack.color)
            case .colorMix: image = applyTreatment(image, stack: stack)
            case .curves: image = applyCurves(image, stack.curves)
            case .detail: image = applyDetail(image, stack.detail, proxyRatio: proxyRatio)
            case .grainAndVignette: image = applyGrainAndVignette(image, stack.effects, proxyRatio: proxyRatio)
            case .glow: image = applyGlow(image, stack.custom, proxyRatio: proxyRatio)
            case .geometry: image = applyGeometry(image, stack.geometry)
            }
        }

        return image
    }

    // MARK: Stage 2 - white balance

    func applyWhiteBalance(_ image: CIImage, _ color: ColorAdjustments, asShot: Double) -> CIImage {
        guard color.temperature != 0 || color.tint != 0 else { return image }
        let target = color.temperature == 0 ? asShot : color.temperature
        let f = CIFilter.temperatureAndTint()
        f.inputImage = image
        f.neutral = CIVector(x: CGFloat(asShot), y: 0)
        f.targetNeutral = CIVector(x: CGFloat(target), y: CGFloat(color.tint))
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: Stage 4 - Optics

    private func applyOptics(_ image: CIImage, _ optics: OpticsAdjustments,
                             correction: FujiLensCorrection?) -> CIImage {
        guard let correction else { return image }
        return Self.lensCorrectionFilter.apply(image, correction: correction,
                                               distortion: optics.correctDistortion,
                                               vignetting: optics.correctVignetting,
                                               chromaticAberration: optics.removeChromaticAberration)
    }

    // MARK: Stage 5 - Light

    private func applyLight(_ image: CIImage, _ light: LightAdjustments) -> CIImage {
        var out = image

        if light.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = out
            f.ev = Float(light.exposure)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        // Highlights and shadows recovered before global contrast, so contrast operates on
        // an already-tamed tonal range - the ordering Lightroom's Basic panel implies.
        if light.highlights != 0 || light.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = out
            // CI takes highlight 0...1 where 1 is neutral; our slider is -100...+100.
            f.highlightAmount = Float(1.0 - max(0, light.highlights) / 100.0 * 0.9
                                          + max(0, -light.highlights) / 100.0 * 0.0)
            f.shadowAmount = Float(light.shadows / 100.0)
            f.radius = 0 // 0 = global, not a local/masked operation (V1 is global only)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        // Whites and blacks are endpoint moves, expressed as a linear remap of the range.
        if light.whites != 0 || light.blacks != 0 {
            let white = 1.0 - light.whites / 400.0
            let black = -light.blacks / 400.0
            let f = CIFilter.colorClamp()
            f.inputImage = out
            f.minComponents = CIVector(x: CGFloat(black), y: CGFloat(black), z: CGFloat(black), w: 0)
            f.maxComponents = CIVector(x: CGFloat(white), y: CGFloat(white), z: CGFloat(white), w: 1)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        if light.contrast != 0 {
            // CIColorControls pivots contrast around 0.5 in the working space. In linear
            // light that is far above mid grey, so it drags the whole image down and a
            // "contrast" move reads as an exposure move. Photographic contrast pivots on
            // an 18% grey card, so do the pivot explicitly:
            //     out = (in - pivot) * k + pivot
            let k = 1.0 + light.contrast / 200.0
            let pivot = Self.middleGreyLinear
            let bias = pivot * (1.0 - k)
            let f = CIFilter.colorMatrix()
            f.inputImage = out
            f.rVector = CIVector(x: CGFloat(k), y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: CGFloat(k), z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: CGFloat(k), w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            f.biasVector = CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0)
            // A biased CIColorMatrix yields infinite extent; restore the finite frame
            // here so contrast cannot widen downstream stages or readback bounds.
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        return out
    }

    // MARK: Stage 7b - HSL mixer and colour grading

    func applyColorMix(_ image: CIImage, _ mix: HSLMix, _ grading: ColorGrading) -> CIImage {
        guard let data = Self.cubeCache.cube(for: mix, grading: grading) else { return image }
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = 17
        f.cubeData = data
        // The cube is authored in display-referred coordinates, matching where the user sees
        // the colours they are adjusting. CI handles the round trip.
        f.colorSpace = WorkingColorSpace.sRGB
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: Stage 8 - Tone curve

    /// Curves are a display-referred operation: users draw them against the histogram, which
    /// is gamma-encoded, so the curve must act in the same space or a point dragged to the
    /// middle of the grid would not land on mid grey. `CIColorCurves.colorSpace` performs
    /// that conversion around the curve and hands the result back in the working space.
    private func applyCurves(_ image: CIImage, _ curves: ToneCurveSet) -> CIImage {
        guard !curves.isNeutral else { return image }

        let resolution = 256
        var data = [Float](repeating: 0, count: resolution * 3)
        for i in 0..<resolution {
            let x = Double(i) / Double(resolution - 1)
            // Composite first, then the per-channel curve on its result.
            let base = curves.composite.value(at: x)
            data[i * 3 + 0] = Float(curves.red.value(at: base))
            data[i * 3 + 1] = Float(curves.green.value(at: base))
            data[i * 3 + 2] = Float(curves.blue.value(at: base))
        }

        let f = CIFilter.colorCurves()
        // CIColorCurves does the working-space -> curve-space -> working-space round trip
        // itself, driven by `colorSpace`. Converting the image manually as well applies the
        // transfer function twice and a point drawn at 128->180 renders as 186.
        f.inputImage = image
        f.curvesData = Data(bytes: data, count: data.count * MemoryLayout<Float>.size)
        f.curvesDomain = CIVector(x: 0, y: 1)
        f.colorSpace = WorkingColorSpace.sRGB
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: Stage 7 - Color

    private func applyColor(_ image: CIImage, _ color: ColorAdjustments) -> CIImage {
        var out = image

        if color.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.saturation = Float(1.0 + color.saturation / 100.0)
            f.contrast = 1
            f.brightness = 0
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        if color.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = out
            f.amount = Float(color.vibrance / 100.0)
            out = (f.outputImage ?? out).cropped(to: image.extent)
        }

        return out
    }
}

/// The pipeline's view of a decoded frame - deliberately narrow, so RenderPipeline stays
/// testable without dragging in the decoder.
public struct DecodedFrameInput: @unchecked Sendable {
    public let image: CIImage
    public let asShotTemperature: Double
    public var lensCorrection: FujiLensCorrection?
    public let profile: CameraProfile?
    public init(image: CIImage, asShotTemperature: Double, lensCorrection: FujiLensCorrection? = nil,
                profile: CameraProfile? = nil) {
        self.profile = profile
        self.image = image
        self.asShotTemperature = asShotTemperature
        self.lensCorrection = lensCorrection
    }
}
