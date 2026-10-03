import Foundation
import CryptoKit

/// Build plan §2: the sidecar is the source of truth; the catalog database is a
/// rebuildable index over it. Plain JSON rather than Core Data so the edit history
/// survives the catalog being deleted, and so the format would not need unpicking
/// if something else ever had to read it.
public enum Sidecar {

    public static let fileExtension = "xtd.json"

    public static func url(forImageAt imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    public static func load(forImageAt imageURL: URL) throws -> EditStack? {
        let side = url(forImageAt: imageURL)
        guard FileManager.default.fileExists(atPath: side.path) else { return nil }
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
