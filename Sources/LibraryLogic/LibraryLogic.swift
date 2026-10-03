import Foundation
import Catalog

public enum LibrarySort: String, CaseIterable, Sendable {
    case captureDate = "Capture date", filename = "Filename", fileDate = "File date", rating = "Rating"

    public func precedes(_ a: ImageRecord, _ b: ImageRecord, fileDates: [String: Date] = [:]) -> Bool {
        switch self {
        case .filename:
            if a.filename != b.filename { return a.filename < b.filename }
        case .captureDate:
            if a.captureDate != b.captureDate { return (a.captureDate ?? .distantPast) < (b.captureDate ?? .distantPast) }
        case .fileDate:
            if fileDates[a.path] != fileDates[b.path] { return (fileDates[a.path] ?? .distantPast) < (fileDates[b.path] ?? .distantPast) }
        case .rating:
            if a.rating != b.rating { return a.rating > b.rating }
        }
        return a.path < b.path
    }
}

public struct LibraryFilter: Equatable, Sendable {
    public var fileType = "All"
    public var minimumRating = 0
    public var flag: Int? = nil
    public init() {}
    public func matches(_ row: ImageRecord) -> Bool {
        (fileType == "All" || row.ext == fileType) && row.rating >= minimumRating && (flag == nil || row.flag == flag)
    }
}

public enum LibraryKey: Equatable, Sendable {
    case rating(Int), flag(Int), open
    public static func map(_ characters: String) -> Self? {
        if characters.count == 1, let rating = Int(characters), (0...5).contains(rating) { return .rating(rating) }
        switch characters.lowercased() {
        case "p": return .flag(1)
        case "x": return .flag(-1)
        case "\r", "\u{3}": return .open
        default: return nil
        }
    }
    public static func move(index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        return min(count - 1, max(0, index + delta))
    }
}

public enum FolderBookmark {
    public static func encode(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public static func decode(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

// Leases can outlive a removed root while a scan or thumbnail still uses its files.
public final class FolderAccess: Sendable {
    public let url: URL
    private let started: Bool
    public init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}
