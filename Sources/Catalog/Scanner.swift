import Foundation
import ImageIO
import EditModel
import RawDecode

public struct ScanResult: Sendable, Equatable {
    public let scanned: Int
    public let updated: Int
    public let skipped: Int
    public let removed: Int

    public init(scanned: Int, updated: Int, skipped: Int, removed: Int = 0) {
        self.scanned = scanned; self.updated = updated; self.skipped = skipped; self.removed = removed
    }
}

public struct FolderScan: Sendable {
    public let progress: AsyncStream<(scanned: Int, total: Int)>
    public let result: Task<ScanResult, Error>

    public func cancel() { result.cancel() }
}

public struct Scanner: Sendable {
    private let catalog: Catalog
    public init(catalog: Catalog) { self.catalog = catalog }

    public func scan(root: URL) -> FolderScan {
        let (stream, continuation) = AsyncStream<(scanned: Int, total: Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached { [catalog] in
            defer { continuation.finish() }
            let extensions = SupportedFormats.all
            let root = root.standardizedFileURL
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            var enumerationError: (any Error)?
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else { throw CatalogError(description: "Cannot enumerate \(root.path)") }
            var files: [URL] = []
            while let url = walker.nextObject() as? URL {
                try Task.checkCancellation()
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                let properties = try url.resourceValues(forKeys: Set(keys))
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                files.append(url.standardizedFileURL)
            }
            if let enumerationError { throw enumerationError }
            continuation.yield((0, files.count))
            var updated = 0
            for (offset, url) in files.enumerated() {
                try Task.checkCancellation()
                let fingerprint = try SourceFingerprint.compute(for: url)
                if try await !catalog.matches(path: url.path, fingerprint: fingerprint) {
                    let metadata = CoreImageRawDecoder.readMetadata(url)
                    var record = ImageRecord(path: url.path, fingerprint: fingerprint)
                    record.captureDate = metadata.captureDate
                    record.cameraModel = metadata.cameraModel.isEmpty ? nil : metadata.cameraModel
                    record.lensModel = metadata.lensModel.isEmpty ? nil : metadata.lensModel
                    record.iso = metadata.iso == 0 ? nil : metadata.iso
                    record.aperture = metadata.aperture == 0 ? nil : metadata.aperture
                    record.shutter = metadata.shutterSeconds == 0 ? nil : metadata.shutterSeconds
                    record.focalLength = metadata.focalLength == 0 ? nil : metadata.focalLength
                    record.isRaw = SupportedFormats.isRaw(record.ext)
                    record.cameraMake = metadata.cameraMake
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                        record.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
                        record.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
                    }
                    // Full paths identify independent sources: a RAF and JPEG with the
                    // same basename must retain separate rows and derivative keys.
                    try await catalog.index(record)
                    updated += 1
                }
                continuation.yield((offset + 1, files.count))
            }
            // Reached only after a full enumeration and index pass without error or cancellation.
            try Task.checkCancellation()
            let removed = try await catalog.prune(under: root.path, keeping: Set(files.map(\.path)))
            return ScanResult(scanned: files.count, updated: updated, skipped: files.count - updated, removed: removed)
        }
        // Progress is optional observation: dropping the stream must not cancel an
        // indexing job whose result is still awaited. FolderScan.cancel owns cancellation.
        return FolderScan(progress: stream, result: task)
    }
}
