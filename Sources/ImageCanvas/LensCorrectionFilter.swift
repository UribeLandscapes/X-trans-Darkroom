import Foundation
import Synchronization
import CoreImage
import RawDecode
import ImagingCore

/// Build plan §6: applying the corrections read out of the RAF.
///
/// Three operations, in the order optics demands:
///   1. Vignetting — a radial gain applied in LINEAR light. Applying it after tone mapping
///      produces visibly wrong corners, which is why it sits here and not later.
///   2. Chromatic aberration — per-channel radial rescale of red and blue about green.
///   3. Distortion — a radial warp.
///
/// The Metal offline compiler is unavailable on this machine, so the warps are built from
/// Core Image Kernel Language at runtime. That API is deprecated but functional, and it is
/// the only route to a custom warp without Xcode. If Xcode is installed later, these become
/// Metal kernels with no change to the call sites.
public final class LensCorrectionFilter: Sendable {

    /// Margin floor for the warp ROI, so small corrections behave as they always did.
    public static let minimumWarpMargin: CGFloat = 32

    private struct GainEntry: Sendable {
        let key: String
        let map: CIImage
    }

    // Kernels are immutable and built once (lazy var initialisation is not thread-safe).
    private let warpKernel: CIWarpKernel?
    private let gainKernel: CIColorKernel?
    private let channelKernel: CIColorKernel?
    /// Cached gain map and its key, read and written together under one lock.
    private let gainState = Mutex<GainEntry?>(nil)

    public init() {
        warpKernel = Self.makeWarpKernel()
        gainKernel = Self.makeGainKernel()
        channelKernel = Self.makeChannelKernel()
    }

    /// Exposes compilation success so verification can detect a silent pass-through.
    public var kernelsAvailable: Bool {
        let warp = warpKernel
        let gain = gainKernel
        let channel = channelKernel
        return warp != nil && gain != nil && channel != nil
    }

    private static func makeWarpKernel() -> CIWarpKernel? {
        // r' = r · (1 + k1r² + k2r⁴ + k3r⁶), evaluated about the frame centre with radius
        // normalized to the half-diagonal so the model is resolution independent (§2).
        let source = """
        kernel vec2 radialWarp(vec2 center, float invRadius, float k1, float k2, float k3) {
            vec2 d = destCoord() - center;
            float r = length(d) * invRadius;
            float r2 = r * r;
            float scale = 1.0 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2;
            return center + d * scale;
        }
        """
        return CIWarpKernel(source: source)
    }

    private static func makeGainKernel() -> CIColorKernel? {
        // Multiplies the image by a gain map. Separate from the warp because vignetting is
        // a photometric correction and distortion is a geometric one.
        let source = """
        kernel vec4 applyGain(__sample image, __sample gain) {
            return vec4(image.rgb * gain.r, image.a);
        }
        """
        return CIColorKernel(source: source)
    }

    private static func makeChannelKernel() -> CIColorKernel? {
        // Recombines three separately-warped images into one, taking R from the first,
        // G from the second and B from the third - how per-channel CA correction works.
        let source = """
        kernel vec4 combine(__sample r, __sample g, __sample b) {
            return vec4(r.r, g.g, b.b, g.a);
        }
        """
        return CIColorKernel(source: source)
    }

    public func apply(_ image: CIImage,
                      correction: FujiLensCorrection,
                      distortion: Bool,
                      vignetting: Bool,
                      chromaticAberration: Bool) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1, !correction.isEmpty else {
            return image
        }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        // Normalize by the half-diagonal: the knot table runs past 1.0 because the corner is
        // further from centre than the edge, and this is the radius that makes that true.
        let halfDiagonal = sqrt(extent.width * extent.width + extent.height * extent.height) / 2
        let invRadius = Float(1 / halfDiagonal)

        var out = image

        if vignetting {
            out = applyVignetting(out, correction: correction, extent: extent, halfDiagonal: halfDiagonal)
        }

        if chromaticAberration {
            let red = correction.redPolynomial
            let blue = correction.bluePolynomial
            if abs(red.k1) > 1e-9 || abs(blue.k1) > 1e-9,
               let kernel = warpKernel, let combine = channelKernel {
                let r = warp(out, kernel: kernel, center: center, invRadius: invRadius, halfDiagonal: halfDiagonal, poly: red)
                let b = warp(out, kernel: kernel, center: center, invRadius: invRadius, halfDiagonal: halfDiagonal, poly: blue)
                out = combine.apply(extent: extent, arguments: [r, out, b]) ?? out
            }
        }

        if distortion, let kernel = warpKernel {
            // The table says how much the lens stretched the image; correcting means
            // applying the inverse, so the polynomial's sign is flipped.
            let p = correction.distortionPolynomial
            let inverse = FujiLensCorrection.RadialPolynomial(k1: -p.k1, k2: -p.k2, k3: -p.k3)
            out = warp(out, kernel: kernel, center: center, invRadius: invRadius, halfDiagonal: halfDiagonal, poly: inverse)
        }

        return out.cropped(to: extent)
    }

    private func warp(_ image: CIImage, kernel: CIWarpKernel, center: CGPoint,
                      invRadius: Float, halfDiagonal: CGFloat,
                      poly: FujiLensCorrection.RadialPolynomial) -> CIImage {
        let margin = Self.warpMargin(poly: poly, halfDiagonal: halfDiagonal)
        return kernel.apply(extent: image.extent,
                     roiCallback: { _, rect in rect.insetBy(dx: -margin, dy: -margin) },
                     image: image,
                     arguments: [CIVector(x: center.x, y: center.y),
                                 invRadius,
                                 Float(poly.k1), Float(poly.k2), Float(poly.k3)]) ?? image
    }

    /// Largest source-pixel displacement the warp can produce, so the ROI covers every sample.
    /// Displacement is |r * (k1 r^2 + k2 r^4 + k3 r^6)| * halfDiagonal with r normalized to the
    /// half-diagonal (1.0 is the corner); sampled out to 1.05 for safety.
    public static func warpMargin(poly: FujiLensCorrection.RadialPolynomial, halfDiagonal: CGFloat) -> CGFloat {
        let steps = 64, rMax = 1.05
        var peak = 0.0
        for i in 0...steps {
            let r = rMax * Double(i) / Double(steps)
            let r2 = r * r
            peak = max(peak, abs(r * (poly.k1 * r2 + poly.k2 * r2 * r2 + poly.k3 * r2 * r2 * r2)))
        }
        let needed = (peak * Double(halfDiagonal)).rounded(.up) + 2
        return max(minimumWarpMargin, CGFloat(needed))
    }

    /// The gain map uses the real nine-knot table rather than a polynomial fit: it is a
    /// smooth photometric falloff, so a modest bitmap upscaled by the GPU is exact enough
    /// and avoids putting a lookup table inside a shader.
    private func applyVignetting(_ image: CIImage, correction: FujiLensCorrection,
                                 extent: CGRect, halfDiagonal: CGFloat) -> CIImage {
        guard let gainKernel else { return image }

        let key = "\(correction.vignetting)|\(Int(extent.width))x\(Int(extent.height))"
        let map: CIImage
        if let hit = gainState.withLock({ $0 }), hit.key == key {
            map = hit.map
        } else {
            let n = 128
            var pixels = [Float](repeating: 0, count: n * n * 4)
            let cx = Double(n - 1) / 2, cy = cx
            let norm = sqrt(cx * cx + cy * cy)
            for y in 0..<n {
                for x in 0..<n {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let r = sqrt(dx * dx + dy * dy) / norm
                    let g = Float(correction.vignettingGain(atRadius: r))
                    let i = (y * n + x) * 4
                    pixels[i] = g; pixels[i + 1] = g; pixels[i + 2] = g; pixels[i + 3] = 1
                }
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            let small = CIImage(bitmapData: data,
                                bytesPerRow: n * 4 * MemoryLayout<Float>.size,
                                size: CGSize(width: n, height: n),
                                format: .RGBAf,
                                colorSpace: nil)
            map = small.transformed(by: .init(scaleX: extent.width / CGFloat(n),
                                              y: extent.height / CGFloat(n)))
                .transformed(by: .init(translationX: extent.minX, y: extent.minY))
            gainState.withLock { $0 = GainEntry(key: key, map: map) }
        }

        return gainKernel.apply(extent: extent, arguments: [image, map]) ?? image
    }
}
