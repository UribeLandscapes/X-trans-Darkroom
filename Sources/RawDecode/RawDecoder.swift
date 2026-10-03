import Foundation
import CoreImage
import ImagingCore

/// Build plan §1: the decoder boundary.
///
/// Contract: *file URL + requested scale -> neutral linear scene-referred CIImage + metadata.*
/// Decoding happens once per image, not once per slider tick, so this protocol governs
/// image-open and thumbnail-build time - not interactive latency.
///
/// Core Image is the V1 implementation. If Phase 0's delta-E measurement shows Apple's
/// demosaic puts us too far from the Lightroom reference, a LibRawDecoder conforms here
/// instead and nothing downstream changes.
public protocol RawDecoder: Sendable {
    func canDecode(_ url: URL) -> Bool
    func decode(_ url: URL, scale: DecodeScale) throws -> DecodedFrame
    func decode(_ url: URL, scale: DecodeScale, builtInLensCorrection: Bool) throws -> DecodedFrame
}

public extension RawDecoder {
    func decode(_ url: URL, scale: DecodeScale, builtInLensCorrection: Bool) throws -> DecodedFrame {
        try decode(url, scale: scale)
    }
}

public enum DecodeScale: Sendable, Equatable {
    /// Full sensor resolution. Used for the settle render and export.
    case full
    /// Fastest decode that yields at least this long-edge size. Used for thumbnails.
    case atLeast(pixels: Int)

    public var isDraft: Bool {
        if case .atLeast = self { return true }
        return false
    }
}

public struct DecodedFrame: @unchecked Sendable {
    public let image: CIImage
    public let pixelSize: CGSize
    public let metadata: CaptureMetadata
    public var asShotSettings: AsShotSettings?
    public var lensCorrection: FujiLensCorrection?
    public init(image: CIImage, pixelSize: CGSize, metadata: CaptureMetadata,
                lensCorrection: FujiLensCorrection? = nil, asShotSettings: AsShotSettings? = nil) {
        self.image = image
        self.pixelSize = pixelSize
        self.metadata = metadata
        self.lensCorrection = lensCorrection
        self.asShotSettings = asShotSettings
    }
}

public struct CaptureMetadata: Sendable, Equatable {
    public var cameraMake: String = ""
    public var cameraModel: String = ""
    public var lensModel: String = ""
    public var focalLength: Double = 0
    public var aperture: Double = 0
    public var shutterSeconds: Double = 0
    public var iso: Int = 0
    public var captureDate: Date?
    /// As-shot white balance recovered from the file, in Kelvin/tint.
    public var asShotTemperature: Double = 5500
    public var asShotTint: Double = 0
    public var isRaw: Bool = false
    public var cameraSource = CameraSource()
    public var isEmbeddedPreviewFallback = false
    public var supportsBuiltInLensCorrection = false
    public var fallbackStatus: String? {
        isEmbeddedPreviewFallback ? "\(cameraModel.isEmpty ? "Unknown camera" : cameraModel) RAW not supported by macOS - editing embedded JPEG preview" : nil
    }
    public init() {}
}

public enum RawDecodeError: Error, CustomStringConvertible {
    case unsupported(URL)
    case decodeFailed(URL, String)

    public var description: String {
        switch self {
        case .unsupported(let u): return "Unsupported file: \(u.lastPathComponent)"
        case .decodeFailed(let u, let why): return "Could not decode \(u.lastPathComponent): \(why)"
        }
    }
}
