import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

extension RenderPipeline {
    private static let glowKernel: CIColorKernel? = {
        // Runtime CIKL compilation, cached once, as in LensCorrectionFilter.
        let source = """
        kernel vec4 applyGlow(__sample base, __sample clamped, __sample blurred, float t) {
            return vec4(base.rgb + t * blurred.rgb * (vec3(1.0) - clamped.rgb), base.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    func applyGlow(_ image: CIImage, _ custom: CustomAdjustments, proxyRatio: Double) -> CIImage {
        let extent = image.extent
        guard custom.glowAmount > 0, !extent.isInfinite, !extent.isNull else { return image }

        // The context works in linear Rec. 2020. Match primaries to linear sRGB first:
        // a tone curve alone would screen Rec. 2020 channels, unlike a Photoshop sRGB
        // document. Explicit encoding keeps both blur and opacity in encoded values.
        guard let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let linear = image.matchedFromWorkingSpace(to: linearSRGB) else { return image }
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = linear
        guard let encoded = encode.outputImage?.cropped(to: extent) else { return image }
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = encoded
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let clamped = clamp.outputImage?.cropped(to: extent) else { return image }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = clamped.clampedToExtent() // Repeat edge pixels, like Photoshop.
        // Both radii are std-dev-like pixel radii: map 1:1, then scale for the proxy.
        blur.radius = Float(custom.glowRadius * proxyRatio)
        // Screen at opacity t simplifies to Ec + t * ((1 - (1 - Ec) * (1 - Bc)) - Ec)
        // = Ec + t * Bc * (1 - Ec). Use the unclamped E as the base so only the glow
        // contribution uses clamped values, preserving extended gamut and highlights.
        guard let blurred = blur.outputImage?.cropped(to: extent),
              let mixed = Self.glowKernel?.apply(extent: extent, arguments: [
                encoded, clamped, blurred, Float(min(custom.glowAmount, 100) / 100)
              ]) else { return image }
        let decode = CIFilter.sRGBToneCurveToLinear()
        decode.inputImage = mixed
        guard let output = decode.outputImage?.matchedToWorkingSpace(from: linearSRGB) else { return image }
        return output.cropped(to: extent)
    }
}
