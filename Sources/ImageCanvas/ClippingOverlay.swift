import CoreImage
import ImagingCore

public enum ClippingOverlay {
    private static let kernel = CIColorKernel(source: """
        kernel vec4 clipping(__sample pixel) {
            vec4 p = unpremultiply(pixel);
            if (max(max(p.r, p.g), p.b) >= 1.0) return vec4(p.a, 0.0, 0.0, p.a);
            if (max(max(p.r, p.g), p.b) <= 0.0) return vec4(0.0, 0.0, p.a, p.a);
            return pixel;
        }
        """)
    /// Input contains encoded Display P3 values, useful for synthetic readback checks.
    public static func applyDisplayValues(_ image: CIImage) -> CIImage {
        kernel?.apply(extent: image.extent, arguments: [image]) ?? image
    }
    public static func apply(_ image: CIImage) -> CIImage {
        // Scene-linear endpoints are not display clipping: gamut/transfer conversion
        // changes channels. Evaluate the same encoded P3 values sent to the drawable.
        guard let display = image.matchedFromWorkingSpace(to: WorkingColorSpace.displayP3),
              let result = applyDisplayValues(display).matchedToWorkingSpace(from: WorkingColorSpace.displayP3)
        else { return image }
        return result.cropped(to: image.extent)
    }
}
