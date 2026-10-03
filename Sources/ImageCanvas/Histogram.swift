import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImagingCore

/// Build plan §3, Phase 3: the histogram.
///
/// Computed from the render output on the GPU via `CIAreaHistogram`, never by iterating
/// pixels on the CPU - a 4 MP CPU pass would eat the entire 8.3 ms interactive budget on
/// its own. It reads the *proxy* render, which is what the user is actually looking at.
///
/// This is chrome and it is styled retro, but the numbers are real: the bin data comes
/// straight from the pipeline output at full precision, never from a palette-reduced or
/// otherwise stylized buffer.
public struct Histogram: Equatable, Sendable {
    public static let binCount = 256

    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]
    public var luma: [Float]

    /// Fraction of pixels sitting at or below 0 / at or above 1 - drives the clipping
    /// indicators in the Light panel.
    public var shadowClipping: Float
    public var highlightClipping: Float

    public static let empty = Histogram(
        red: Array(repeating: 0, count: binCount),
        green: Array(repeating: 0, count: binCount),
        blue: Array(repeating: 0, count: binCount),
        luma: Array(repeating: 0, count: binCount),
        shadowClipping: 0, highlightClipping: 0)
}

public final class HistogramComputer: @unchecked Sendable {

    private let context: CIContext

    public init(context: CIContext? = nil) {
        self.context = context ?? CIContext(options: [
            .workingColorSpace: WorkingColorSpace.linearWide,
            .cacheIntermediates: false
        ])
    }

    /// Returns nil if the image has no usable extent. Cheap enough to run per settle
    /// render; during a drag it runs at most once per display refresh alongside the proxy.
    public func compute(_ image: CIImage) -> Histogram? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }

        // Bin in DISPLAY-REFERRED space, not the linear working space. A linear histogram
        // crushes everything into the left third - mid grey lands at bin 55 instead of 128 -
        // and is unreadable as a photographic tool. Lightroom's histogram is gamma-encoded
        // and so is this one, so what the user sees matches what they expect to see.
        let displayReferred = image.matchedFromWorkingSpace(to: WorkingColorSpace.sRGB)
            ?? image

        let filter = CIFilter.areaHistogram()
        filter.inputImage = displayReferred
        filter.extent = displayReferred.extent
        filter.count = Histogram.binCount
        filter.scale = 1
        guard let output = filter.outputImage else { return nil }

        // The histogram filter returns a 256x1 image where each pixel's RGBA holds the
        // per-channel bin counts. Read it back as float so bright bins do not clip.
        // The histogram image holds bin COUNTS, not colours. Handing `render` a colour
        // space makes it apply a transfer function to that count data and the result comes
        // back as zeros. It must be nil.
        var raw = [Float](repeating: 0, count: Histogram.binCount * 4)
        raw.withUnsafeMutableBytes { buffer in
            context.render(output,
                           toBitmap: buffer.baseAddress!,
                           rowBytes: Histogram.binCount * 4 * MemoryLayout<Float>.size,
                           bounds: output.extent,
                           format: .RGBAf,
                           colorSpace: nil)
        }

        var r = [Float](repeating: 0, count: Histogram.binCount)
        var g = r, b = r, l = r
        for i in 0..<Histogram.binCount {
            r[i] = raw[i * 4 + 0]
            g[i] = raw[i * 4 + 1]
            b[i] = raw[i * 4 + 2]
            // Rec. 709 luma, the standard weighting for a photographic luminance readout.
            l[i] = 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i]
        }

        // Normalize to the tallest bin so the display is scale independent. The very first
        // and last bins are excluded from the peak: a large pure-black or blown-white area
        // would otherwise flatten the entire rest of the curve to invisibility.
        let interior = l.dropFirst().dropLast()
        let peak = max(interior.max() ?? 1, 1e-6)
        for i in 0..<Histogram.binCount {
            r[i] /= peak; g[i] /= peak; b[i] /= peak; l[i] /= peak
        }

        let total = max(l.reduce(0, +), 1e-6)
        return Histogram(red: r, green: g, blue: b, luma: l,
                         shadowClipping: l.first! / total,
                         highlightClipping: l.last! / total)
    }
}
