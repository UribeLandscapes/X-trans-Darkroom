import Foundation
import CryptoKit
import RawDecode

/// Build plan §2: the sidecar is the source of truth; the catalog database is a
/// rebuildable index over it. Plain JSON rather than Core Data so the edit history
/// survives the catalog being deleted, and so the format would not need unpicking
/// if something else ever had to read it.
public enum Sidecar {

    public static let fileExtension = "xtd.json"

    /// The sidecar name keeps the full image filename (DSCF0001.RAF.xtd.json), so a RAW and
    /// its JPEG sibling never share one file and overwrite each other's edits.
    public static func url(forImageAt imageURL: URL) -> URL {
        imageURL.appendingPathExtension(fileExtension)
    }

    /// Pre-fix name (DSCF0001.xtd.json), shared by every file with the same stem.
    static func legacyURL(forImageAt imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    /// Legacy migration rule. A legacy sidecar is read (never moved or deleted, so no
    /// sibling can lose edits) only when ownership is unambiguous:
    ///  - the image is the only supported file in its folder with that stem, or
    ///  - several share the stem and this image is the single RAW among them.
    /// Anything else (e.g. JPG+PNG, two RAWs, the JPG of a RAW+JPG pair) adopts nothing.
    /// A new-style sidecar, once saved, always takes precedence.
    public static func ownsLegacySidecar(
        _ imageURL: URL,
        listing: (URL) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0.path) }
    ) -> Bool {
        let dir = imageURL.deletingLastPathComponent()
        let stem = imageURL.deletingPathExtension().lastPathComponent.lowercased()
        // Unlistable folder: ownership cannot be confirmed, so adopt nothing.
        guard let names = try? listing(dir) else { return false }
        let siblings = names.map { dir.appendingPathComponent($0) }.filter {
            SupportedFormats.contains($0) && $0.deletingPathExtension().lastPathComponent.lowercased() == stem
        }
        // The confirmed set must contain this image itself.
        guard siblings.contains(where: { $0.lastPathComponent == imageURL.lastPathComponent }) else { return false }
        guard siblings.count > 1 else { return true }
        let raws = siblings.filter { SupportedFormats.isRaw($0.pathExtension) }
        return raws.count == 1 && raws[0].lastPathComponent == imageURL.lastPathComponent
    }

    public static func load(forImageAt imageURL: URL) throws -> EditStack? {
        var side = url(forImageAt: imageURL)
        if !FileManager.default.fileExists(atPath: side.path) {
            let legacy = legacyURL(forImageAt: imageURL)
            guard FileManager.default.fileExists(atPath: legacy.path), ownsLegacySidecar(imageURL) else { return nil }
            side = legacy
        }
        let data = try Data(contentsOf: side)
        return try JSONDecoder().decode(EditStack.self, from: data)
    }

    /// Atomic write. A half-written sidecar would silently lose a session of edits.
    public static func save(_ stack: EditStack, forImageAt imageURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stack)
        try data.write(to: url(forImageAt: imageURL), options: .atomic)
    }

    public static func delete(forImageAt imageURL: URL) throws {
        let side = url(forImageAt: imageURL)
        if FileManager.default.fileExists(atPath: side.path) {
            try FileManager.default.removeItem(at: side)
        }
    }
}

/// Build plan §7: cache and catalog key. Path + inode + mtime + size, so an externally
/// modified file yields a different fingerprint and its derivatives regenerate without
/// any explicit invalidation pass.
public enum SourceFingerprint {
    public static func compute(for url: URL) throws -> String {
        // NB: URL.resourceValues caches on the URL instance, so re-reading the same URL
        // object after the file changed returns stale values. FileManager reads fresh.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        var hasher = SHA256()
        hasher.update(data: Data(url.standardizedFileURL.path.utf8))
        hasher.update(data: withUnsafeBytes(of: size) { Data($0) })
        hasher.update(data: withUnsafeBytes(of: mtime) { Data($0) })
        hasher.update(data: withUnsafeBytes(of: inode) { Data($0) })
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
