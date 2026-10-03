import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ImagingCore

/// Build plan §1, V1 decoder.
///
/// Critical detail: Apple's RAW pipeline applies its own boost, sharpening and noise
/// reduction by default. All three are disabled here so the decoder hands back the
/// flattest linear starting point available - our camera profile and tone curve do the
/// rendering, not Apple's. Phase 0 Spike A measures how neutral the result actually is.
public struct CoreImageRawDecoder: RawDecoder {

    public var builtInLensCorrection: Bool
    public init(builtInLensCorrection: Bool = true) { self.builtInLensCorrection = builtInLensCorrection }

    public func canDecode(_ url: URL) -> Bool { SupportedFormats.contains(url) }

    public func decode(_ url: URL, scale: DecodeScale, builtInLensCorrection: Bool) throws -> DecodedFrame {
        try Self(builtInLensCorrection: builtInLensCorrection).decode(url, scale: scale)
    }

    public func decode(_ url: URL, scale: DecodeScale) throws -> DecodedFrame {
        let ext = url.pathExtension.lowercased()
        let metadata = Self.readMetadata(url)

        if SupportedFormats.raw.contains(ext) {
            return try decodeRaw(url, scale: scale, metadata: metadata)
        }
        if SupportedFormats.rendered.contains(ext) {
            return try decodeRendered(url, scale: scale, metadata: metadata)
        }
        throw RawDecodeError.unsupported(url)
    }

    // MARK: RAW

    private func decodeRaw(_ url: URL, scale: DecodeScale, metadata: CaptureMetadata) throws -> DecodedFrame {
        guard let filter = CIRAWFilter(imageURL: url) else {
            return try embeddedPreview(url, scale: scale, metadata: metadata)
        }

        // Neutralise Apple's own rendering so the profile stage (§4) owns the look.
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.isGamutMappingEnabled = false
        filter.sharpnessAmount = 0
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.detailAmount = 0
        filter.contrastAmount = 0
        filter.localToneMapAmount = 0
        filter.extendedDynamicRangeAmount = 0

        // CIRAWFilter applies EXIF orientation for every RAW, including portrait CR3/DNG.
        // Fuji tables own RAF correction; enabling Apple here would correct it twice.
        filter.isLensCorrectionEnabled = metadata.cameraSource.usesBuiltInLensCorrection(
            supported: filter.isLensCorrectionSupported, enabled: builtInLensCorrection)
        let native = filter.nativeSize
        if case .atLeast(let pixels) = scale {
            let longEdge = max(native.width, native.height)
            if longEdge > 0 {
                let ratio = min(1.0, Double(pixels) / Double(longEdge))
                // Draft mode is the fast path and is only ever used for derivatives,
                // never for the settle render or export (§7).
                filter.isDraftModeEnabled = true
                filter.scaleFactor = Float(max(ratio, 0.03125))
            }
        } else {
            filter.isDraftModeEnabled = false
            filter.scaleFactor = 1.0
        }

        guard let image = filter.outputImage else {
            return try embeddedPreview(url, scale: scale, metadata: metadata)
        }

        var meta = metadata
        meta.isRaw = true
        meta.supportsBuiltInLensCorrection = filter.isLensCorrectionSupported && !meta.cameraSource.isFujifilmRAF
        meta.asShotTemperature = Double(filter.neutralTemperature)
        meta.asShotTint = Double(filter.neutralTint)

        return DecodedFrame(image: image, pixelSize: image.extent.size, metadata: meta,
                            lensCorrection: meta.cameraSource.isFujifilmRAF ? FujiLensCorrection.read(from: url) : nil,
                            asShotSettings: meta.cameraSource.isFujifilmRAF ? AsShotSettings.read(from: url) : nil)
    }

    // MARK: Rendered (JPEG / HEIC / TIFF / PNG)

    private func decodeRendered(_ url: URL, scale: DecodeScale, metadata: CaptureMetadata) throws -> DecodedFrame {
        // Ignore HDR gain maps: edit the SDR base in half-float so 10-bit HEIF is not quantized.
        // Load in the working space, applying the file's own ICC profile, then let the
        // pipeline operate in linear light like any other source.
        let options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .cacheImmediately: true,
            .expandToHDR: false
        ]
        guard var image = CIImage(contentsOf: url, options: options) else {
            throw RawDecodeError.decodeFailed(url, "CIImage could not open the file")
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let depth = properties[kCGImagePropertyDepth] as? Int, depth > 8 {
            let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide, .workingFormat: CIFormat.RGBAh])
            guard let half = context.createCGImage(image, from: image.extent, format: .RGBAh,
                                                   colorSpace: WorkingColorSpace.linearWide, deferred: true) else {
                throw RawDecodeError.decodeFailed(url, "Could not load rendered image at half-float precision")
            }
            image = CIImage(cgImage: half)
        }
        return renderedFrame(image, scale: scale, metadata: metadata)
    }

    private func renderedFrame(_ source: CIImage, scale: DecodeScale, metadata: CaptureMetadata) -> DecodedFrame {
        var image = source
        if case .atLeast(let pixels) = scale {
            let longEdge = max(image.extent.width, image.extent.height)
            if longEdge > CGFloat(pixels) {
                let ratio = CGFloat(pixels) / longEdge
                image = image.transformed(by: .init(scaleX: ratio, y: ratio))
            }
        }

        return DecodedFrame(image: image, pixelSize: image.extent.size, metadata: metadata)
    }

    private func embeddedPreview(_ url: URL, scale: DecodeScale, metadata: CaptureMetadata) throws -> DecodedFrame {
        guard metadata.cameraSource.needsEmbeddedPreview(filterAvailable: false, outputAvailable: false),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            throw RawDecodeError.decodeFailed(url, "RAW and embedded preview unavailable")
        }
        // No max-pixel-size option: retain the full embedded preview, never a tiny icon.
        var meta = metadata
        meta.isEmbeddedPreviewFallback = true
        return renderedFrame(CIImage(cgImage: cg), scale: scale, metadata: meta)
    }

    // MARK: Metadata

    public static func readMetadata(_ url: URL) -> CaptureMetadata {
        var meta = CaptureMetadata()
        meta.cameraSource = CameraSource.read(url)
        meta.isRaw = meta.cameraSource.isRaw
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return meta }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            meta.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
            meta.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            meta.lensModel = exif[kCGImagePropertyExifLensModel] as? String ?? ""
            meta.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double ?? 0
            meta.aperture = exif[kCGImagePropertyExifFNumber] as? Double ?? 0
            meta.shutterSeconds = exif[kCGImagePropertyExifExposureTime] as? Double ?? 0
            if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] { meta.iso = isos.first ?? 0 }
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
                meta.captureDate = fmt.date(from: s)
            }
        }
        meta.cameraSource = CameraSource.read(url, make: meta.cameraMake)
        return meta
    }
}
