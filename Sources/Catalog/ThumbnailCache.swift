import Foundation
import CryptoKit
import CoreImage
import RawDecode

public enum ThumbnailSize: Int, Sendable, CaseIterable {
    case grid = 512
    case preview = 2560
}

// Suspended waiters use no threads; decode work is limited even while the cache
// actor is reentrant and many callers request different sources simultaneously.
private actor ThumbnailWorkers {
    private var available = max(1, ProcessInfo.processInfo.activeProcessorCount)
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().resume() }
    }
}

public actor ThumbnailCache {
    public nonisolated let root: URL
    public let byteCeiling: Int64
    private let workers = ThumbnailWorkers()
    private var pending: [String: Task<URL, Error>] = [:]

    public init(root: URL? = nil, byteCeiling: Int64 = 25_000_000_000) throws {
        guard byteCeiling >= 0 else { throw CatalogError(description: "Cache ceiling must be nonnegative") }
        // Application Support keeps derivatives available mid-session: the OS may
        // purge Caches independently of our byte ceiling and LRU policy.
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("XTransDarkroom/Thumbnails", isDirectory: true)
        self.byteCeiling = byteCeiling
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try Self.trim(root: self.root, byteCeiling: byteCeiling)
    }

    /// Bump whenever rendering output changes for the same edit stack (new or altered
    /// filter maths), so cached thumbnails from the old renderer are never reused.
    public nonisolated static let renderVersion = "render-2"

    public nonisolated static func key(fingerprint: String, editHash: String, size: ThumbnailSize) -> String {
        // Length framing avoids ambiguous concatenation. Including the edit hash
        // makes stale thumbnails structurally impossible, without invalidation passes.
        let components = [fingerprint, editHash, String(size.rawValue), renderVersion]
        var hash = SHA256()
        for component in components {
            hash.update(data: Data("\(component.utf8.count):".utf8))
            hash.update(data: Data(component.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated func fileURL(fingerprint: String, editHash: String, size: ThumbnailSize) -> URL {
        let key = Self.key(fingerprint: fingerprint, editHash: editHash, size: size)
        return root.appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(key.dropFirst(2).prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key)-\(size.rawValue).heic")
    }

    public func cachedURL(fingerprint: String, editHash: String, size: ThumbnailSize) throws -> URL? {
        let url = fileURL(fingerprint: fingerprint, editHash: editHash, size: size)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Persist access order so restarting the app doesn't turn LRU into creation order.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// The callback must apply the edit stack identified by editHash, at derivative
    /// resolution. Requiring it for edited requests prevents accidentally caching a
    /// neutral decode under an edited key; the cache has no dependency on canvas/UI.
    public func thumbnail(for source: URL, fingerprint: String, editHash: String,
                          size: ThumbnailSize, builtInLensCorrection: Bool = true,
                          render: @escaping @Sendable (DecodedFrame) throws -> CIImage) async throws -> URL {
        guard SupportedFormats.contains(source) else { throw RawDecodeError.unsupported(source) }
        if let url = try cachedURL(fingerprint: fingerprint, editHash: editHash, size: size) { return url }
        let key = Self.key(fingerprint: fingerprint, editHash: editHash, size: size)
        if let task = pending[key] { return try await task.value }
        let destination = fileURL(fingerprint: fingerprint, editHash: editHash, size: size)
        let task = Task.detached { [workers, self] in
            await workers.acquire()
            do {
                try Task.checkCancellation()
                let data = try autoreleasepool {
                    let frame = try CoreImageRawDecoder(builtInLensCorrection: builtInLensCorrection).decode(source, scale: .atLeast(pixels: size.rawValue))
                    var image = try render(frame)
                    let extent = image.extent
                    guard !extent.isEmpty, !extent.isInfinite, !extent.isNull else {
                        throw CatalogError(description: "Invalid thumbnail extent")
                    }
                    let ratio = min(1, CGFloat(size.rawValue) / max(extent.width, extent.height))
                    image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                        .transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
                    let context = CIContext()
                    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                          let data = context.heifRepresentation(of: image, format: .RGBA8,
                            colorSpace: colorSpace, options: [:]) else {
                        throw CatalogError(description: "Could not encode HEIC thumbnail")
                    }
                    return data
                }
                let url = try await persist(data, at: destination)
                await workers.release()
                return url
            } catch {
                await workers.release()
                throw error
            }
        }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }

    public func thumbnail(for source: URL, fingerprint: String, size: ThumbnailSize) async throws -> URL {
        try await thumbnail(for: source, fingerprint: fingerprint, editHash: "", size: size) { $0.image }
    }

    public func evict() throws { try Self.trim(root: root, byteCeiling: byteCeiling) }

    public func byteCount() throws -> Int64 {
        try Self.entries(root: root).reduce(0) { $0 + $1.bytes }
    }

    private func persist(_ data: Data, at url: URL) throws -> URL {
        guard Int64(data.count) <= byteCeiling else {
            throw CatalogError(description: "Thumbnail (\(data.count) bytes) exceeds cache ceiling (\(byteCeiling))")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try Self.trim(root: root, byteCeiling: byteCeiling)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Preview-first eviction can legitimately discard a new preview when
            // grids fill the budget. Never hand the caller a URL that doesn't exist.
            throw CatalogError(description: "Thumbnail evicted to preserve grid thumbnails within the cache ceiling")
        }
        return url
    }

    private struct Entry {
        let url: URL
        let bytes: Int64
        let accessed: Date
        let preview: Bool
    }

    private static func entries(root: URL) throws -> [Entry] {
        var error: (any Error)?
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { _, failure in error = failure; return false }) else {
            throw CatalogError(description: "Cannot enumerate thumbnail cache")
        }
        var entries: [Entry] = []
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "heic" else { continue }
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            entries.append(Entry(url: url, bytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                accessed: attrs[.modificationDate] as? Date ?? .distantPast,
                preview: url.lastPathComponent.hasSuffix("-2560.heic")))
        }
        if let error { throw error }
        return entries
    }

    private static func trim(root: URL, byteCeiling: Int64) throws {
        let entries = try entries(root: root).sorted {
            if $0.preview != $1.preview { return $0.preview }
            if $0.accessed != $1.accessed { return $0.accessed < $1.accessed }
            return $0.url.path < $1.url.path
        }
        var bytes = entries.reduce(Int64(0)) { $0 + $1.bytes }
        for entry in entries where bytes > byteCeiling {
            try FileManager.default.removeItem(at: entry.url)
            bytes -= entry.bytes
        }
    }
}
