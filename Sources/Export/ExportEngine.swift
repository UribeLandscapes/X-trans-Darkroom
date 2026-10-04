import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import ImagingCore
import ImageCanvas
import RawDecode
import Profiles
import LibraryLogic
import Synchronization
import Darwin

// The lock makes cancellation visible during synchronous decode/encoding without
// requiring the worker actor to service another message first.
public final class ExportCancellation: Sendable {
    private let cancelled = Mutex(false)
    public init() {}
    public func cancel() { cancelled.withLock { $0 = true } }
    public func check() throws {
        if cancelled.withLock({ $0 }) || Task.isCancelled { throw CancellationError() }
    }
}
public struct ExportProgress: Sendable {
    public let index: Int
    public let total: Int
    public let filename: String
    public let fraction: Double
}
public struct ExportResult: Sendable {
    public let source: URL
    public let output: URL?
    public let error: String?
}

public actor ExportEngine {
    private let pipeline = RenderPipeline()
    private let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide, .cacheIntermediates: false])
    /// Hard-link primitive (source, destination) -> 0, or -1 with errno set. Injectable so
    /// checks can simulate volumes without hard links (exFAT, some network shares).
    public typealias LinkOperation = @Sendable (String, String) -> Int32
    private let linkOperation: LinkOperation
    /// Runs after the fallback copy wrote its bytes, before fsync, with the destination path.
    /// Throwing simulates a copy failure; checks use it to race another writer.
    public typealias AfterCopy = @Sendable (String) throws -> Void
    private let afterCopy: AfterCopy
    public init(link: @escaping LinkOperation = { Darwin.link($0, $1) }, afterCopy: @escaping AfterCopy = { _ in }) {
        linkOperation = link
        self.afterCopy = afterCopy
    }

    public func run(_ request: ExportRequest, cancellation: ExportCancellation = ExportCancellation(),
                    progress: @Sendable (ExportProgress) async -> Void = { _ in }) async -> [ExportResult] {
        let access = FolderAccess(request.destination)
        defer { withExtendedLifetime(access) {} }
        let profiles = ProfileLibrary()
        var results: [ExportResult] = []
        for (index, item) in request.items.enumerated() {
            do {
                try cancellation.check()
                await progress(.init(index: index, total: request.items.count, filename: item.source.lastPathComponent, fraction: 0))
                try cancellation.check()
                let output = try await export(item, request: request, index: index + 1, profiles: profiles, cancellation: cancellation) { fraction in
                    await progress(.init(index: index, total: request.items.count, filename: item.source.lastPathComponent, fraction: fraction))
                }
                results.append(.init(source: item.source, output: output, error: nil))
                await progress(.init(index: index, total: request.items.count, filename: item.source.lastPathComponent, fraction: 1))
            } catch is CancellationError { break }
            catch { results.append(.init(source: item.source, output: nil, error: String(describing: error))) }
        }
        return results
    }

    private func export(_ item: ExportItem, request: ExportRequest, index: Int, profiles: ProfileLibrary,
                        cancellation: ExportCancellation, progress: @Sendable (Double) async -> Void) async throws -> URL? {
        guard SupportedFormats.contains(item.source) else { throw RawDecodeError.unsupported(item.source) }
        let sourceAccess = FolderAccess(item.source)
        defer { withExtendedLifetime((sourceAccess, item.access)) {} }
        let options = request.options
        let base = try options.basename(source: item.source, index: index)
        let ext = options.format == .jpeg ? "jpg" : "tif"
        let desired = request.destination.appendingPathComponent(base).appendingPathExtension(ext)
        if options.collision == .skip && FileManager.default.fileExists(atPath: desired.path) { return nil }
        if options.collision == .overwrite && Self.isProtectedOriginal(desired, batchSources: request.items.map(\.source)) {
            throw ExportError.sourceWouldBeOverwritten
        }
        let frame = try CoreImageRawDecoder(builtInLensCorrection: item.stack.optics.builtInLensCorrection).decode(item.source, scale: .full)
        try cancellation.check()
        await progress(0.2)
        try cancellation.check()
        let input = DecodedFrameInput(image: frame.image, asShotTemperature: frame.metadata.asShotTemperature,
                                      lensCorrection: frame.lensCorrection,
                                      profile: profiles.resolve(identifier: item.stack.profileID, cameraModel: frame.metadata.cameraModel))
        let rendered = pipeline.render(input, stack: item.stack, proxyRatio: 1)
        let image = try Self.finish(rendered, options: options)
        try cancellation.check()
        guard let cg = context.createCGImage(image, from: image.extent,
                                             format: options.format == .tiff && options.tiffDepth == .sixteen ? .RGBA16 : .RGBA8,
                                             colorSpace: options.colorSpace.cgColorSpace) else { throw ExportError.encodingFailed }
        try cancellation.check()
        await progress(0.7)
        try cancellation.check()
        // A sibling temporary file allows an atomic publish. Cancellation/error can only
        // remove the temporary file, never a completed earlier export or existing target.
        let temporary = request.destination.appendingPathComponent(".xtd-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                (options.format == .jpeg ? UTType.jpeg.identifier : UTType.tiff.identifier) as CFString, 1, nil) else { throw ExportError.encodingFailed }
        var metadata = Self.metadata(from: item.source, policy: options.metadata)
        metadata[kCGImageDestinationLossyCompressionQuality as String] = min(100, max(0, options.jpegQuality)) / 100
        if options.format == .tiff {
            var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression as String] = options.tiffCompression == .lzw ? 5 : 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        // ImageIO embeds the CGImage's ICC data; the same space above performs the
        // actual output transform, rather than relabelling working-space pixels.
        CGImageDestinationAddImage(destination, cg, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
        try cancellation.check()
        await progress(0.9)
        try cancellation.check()
        var output = desired
        var suffix = 0
        while true {
            try cancellation.check()
            if options.collision == .overwrite {
                guard rename(temporary.path, output.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return output
            }
            // link is exclusive, so another writer cannot steal a checked-free filename.
            // Volumes without hard links (exFAT) fall back to an O_EXCL create-and-copy,
            // which is equally exclusive.
            if try publishExclusively(temporary, as: output) { return output }
            if options.collision == .skip { return nil }
            suffix += 1
            output = request.destination.appendingPathComponent("\(base)_\(suffix)").appendingPathExtension(ext)
        }
    }

    /// Errors meaning "this volume cannot hard link", as opposed to a real failure.
    static let linkUnsupportedErrors: Set<Int32> = [ENOTSUP, EPERM, EXDEV, ENOSYS, EMLINK]

    /// Publishes without ever replacing an existing file. Returns false when the name is
    /// already taken. Hard link first; if the volume cannot link, create the destination
    /// with O_CREAT|O_EXCL (fails with EEXIST rather than truncating) and copy the bytes.
    private func publishExclusively(_ temporary: URL, as output: URL) throws -> Bool {
        if linkOperation(temporary.path, output.path) == 0 { return true }
        let linkError = errno
        if linkError == EEXIST { return false }
        guard Self.linkUnsupportedErrors.contains(linkError) else {
            throw POSIXError(POSIXErrorCode(rawValue: linkError) ?? .EIO)
        }
        return try Self.copyExclusively(temporary, to: output, afterCopy: afterCopy)
    }

    /// Never deletes on failure: without an atomic "remove only if mine" on exFAT, any unlink
    /// could destroy another writer's file. The partial file is reported instead.
    private static func copyExclusively(_ source: URL, to destination: URL, afterCopy: AfterCopy) throws -> Bool {
        let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if out < 0 {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(out) }
        do {
            try copyBytes(from: source, to: out)
            try afterCopy(destination.path)
            guard fsync(out) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            throw PartialExportError(path: destination.path, underlying: String(describing: error))
        }
        return true
    }

    private static func copyBytes(from source: URL, to out: Int32) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try chunk.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(out, buffer.baseAddress! + offset, buffer.count - offset)
                    guard written >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
        }
    }

    /// Overwrite must never destroy an original: any source of the batch, or an existing
    /// importable photo sitting in a folder the batch reads from (exporting photo.raf to
    /// photo.jpg beside it). Exports into other folders may replace earlier outputs.
    public static func isProtectedOriginal(_ destination: URL, batchSources: [URL]) -> Bool {
        let target = destination.resolvingSymlinksInPath()
        let sources = batchSources.map { $0.resolvingSymlinksInPath() }
        if sources.contains(target) { return true }
        guard SupportedFormats.contains(target), FileManager.default.fileExists(atPath: target.path) else { return false }
        let folder = target.deletingLastPathComponent().path
        return sources.contains { $0.deletingLastPathComponent().path == folder }
    }

    public static func finish(_ rendered: CIImage, options: ExportOptions) throws -> CIImage {
        let extent = rendered.extent
        guard !extent.isInfinite, !extent.isNull, extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1 else { throw ExportError.invalidDimensions }
        let size = options.dimensions(width: Int(extent.width), height: Int(extent.height))
        var image = rendered.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
        if size.width != Int(extent.width) || size.height != Int(extent.height) {
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(Double(size.height) / extent.height)
            filter.aspectRatio = Float((Double(size.width) / extent.width) / (Double(size.height) / extent.height))
            image = filter.outputImage ?? image
        }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        image = image.cropped(to: bounds)
        if options.sharpening != .none {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image.clampedToExtent()
            filter.radius = options.sharpening == .screen ? 0.6 : options.sharpening == .glossy ? 0.9 : 1.2
            filter.intensity = options.sharpeningAmount == .low ? 0.3 : options.sharpeningAmount == .standard ? 0.6 : 1
            image = (filter.outputImage ?? image).cropped(to: bounds)
        }
        return image
    }

    public static func metadata(from url: URL, policy: MetadataPolicy) -> [String: Any] {
        guard policy != .none, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
        if policy == .copyrightOnly {
            let tiff = original[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let iptc = original[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            var result: [String: Any] = [:]
            if let copyright = tiff[kCGImagePropertyTIFFCopyright as String] {
                result[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFCopyright as String: copyright]
            }
            if let copyright = iptc[kCGImagePropertyIPTCCopyrightNotice as String] {
                result[kCGImagePropertyIPTCDictionary as String] = [kCGImagePropertyIPTCCopyrightNotice as String: copyright]
            }
            return result
        }
        var result = original
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyOrientation,
                    kCGImagePropertyFileSize, kCGImagePropertyHasAlpha] { result.removeValue(forKey: key as String) }
        if policy == .withoutGPS { result.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        // Source orientation and dimensions describe unedited pixels and must not make
        // readers rotate again or report stale dimensions after crop/resize.
        for key in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary] {
            if var values = result[key as String] as? [String: Any] {
                for field in [kCGImagePropertyTIFFOrientation, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension] {
                    values.removeValue(forKey: field as String)
                }
                result[key as String] = values
            }
        }
        return result
    }
}
