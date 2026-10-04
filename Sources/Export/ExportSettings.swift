import Foundation
import ImagingCore
import EditModel
import LibraryLogic

public enum ExportFormat: String, CaseIterable, Sendable { case jpeg = "JPEG", tiff = "TIFF" }
public enum TIFFDepth: Int, CaseIterable, Sendable { case eight = 8, sixteen = 16 }
public enum TIFFCompression: String, CaseIterable, Sendable { case lzw = "LZW", none = "None" }
public enum ResizeMode: String, CaseIterable, Sendable { case none = "None", longEdge = "Long edge", shortEdge = "Short edge", megapixels = "Megapixels" }
public enum OutputSharpening: String, CaseIterable, Sendable { case none = "None", screen = "Screen", matte = "Matte", glossy = "Glossy" }
public enum SharpeningAmount: String, CaseIterable, Sendable { case low = "Low", standard = "Standard", high = "High" }
public enum MetadataPolicy: String, CaseIterable, Sendable { case all = "All", withoutGPS = "All minus GPS", copyrightOnly = "Copyright only", none = "None" }
public enum FilenamePolicy: String, CaseIterable, Sendable { case original = "Original", suffix = "Original + suffix", pattern = "Token pattern" }
public enum CollisionPolicy: String, CaseIterable, Sendable { case addIndex = "Add index", overwrite = "Overwrite", skip = "Skip" }

public struct ExportOptions: Sendable {
    public var format: ExportFormat = .jpeg
    public var jpegQuality = 90.0
    public var tiffDepth: TIFFDepth = .eight
    public var tiffCompression: TIFFCompression = .lzw
    public var colorSpace: OutputColorSpace = .sRGB
    public var resize: ResizeMode = .none
    public var resizeValue = 2048.0
    public var sharpening: OutputSharpening = .screen
    public var sharpeningAmount: SharpeningAmount = .standard
    public var metadata: MetadataPolicy = .withoutGPS
    public var filename: FilenamePolicy = .suffix
    public var suffix = "_edit"
    public var pattern = "{name}_{index}"
    public var collision: CollisionPolicy = .addIndex
    public init() {}

    public func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let w = Double(width), h = Double(height)
        let value = resizeValue.isFinite ? max(resize == .megapixels ? 0.000001 : 1, resizeValue) : max(w, h)
        let ratio: Double
        switch resize {
        case .none: ratio = 1
        case .longEdge: ratio = min(1, value / max(w, h))
        case .shortEdge: ratio = min(1, value / min(w, h))
        case .megapixels: ratio = min(1, sqrt(value * 1_000_000 / (w * h)))
        }
        return (max(1, Int((w * ratio).rounded(.down))), max(1, Int((h * ratio).rounded(.down))))
    }

    public func basename(source: URL, index: Int) throws -> String {
        let name = source.deletingPathExtension().lastPathComponent
        let result: String
        switch filename {
        case .original: result = name
        case .suffix: result = name + suffix
        case .pattern: result = pattern.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{index}", with: String(index))
        }
        guard !result.isEmpty, result != ".", result != "..", !result.contains("/"), !result.contains(":"), !result.contains("\0"), !result.contains("{"), !result.contains("}") else { throw ExportError.invalidFilename }
        return result
    }
}

public struct ExportItem: Sendable {
    public let source: URL
    public let stack: EditStack
    public let access: FolderAccess?
    public init(source: URL, stack: EditStack, access: FolderAccess? = nil) {
        self.source = source; self.stack = stack; self.access = access
    }
}

public struct ExportRequest: Identifiable, Sendable {
    public let id = UUID()
    public let items: [ExportItem]
    public var destination: URL
    public let initialDestination: URL
    public var makeDefault = false
    public var options = ExportOptions()
    public var isOneOff: Bool { destination.standardizedFileURL.resolvingSymlinksInPath().path != initialDestination.standardizedFileURL.resolvingSymlinksInPath().path }
    /// Explicit destinations need no persisted folder bookmark (e.g. temporary shares).
    public init(items: [ExportItem], destination: URL) {
        self.items = items
        self.destination = destination
        initialDestination = destination
    }

    public init(items: [ExportItem], settings: ExportSettings) throws {
        self.items = items
        destination = try settings.destination()
        initialDestination = destination
    }
}

// Only this object owns persistence; a request remains disposable sheet state.
public final class ExportSettings {
    public static let bookmarkKey = "export.defaultDestinationBookmark"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    public func destination() throws -> URL {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else {
            // Bookmarking Downloads can prompt for access. Defer it until an export needs a destination.
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            try setDefault(url)
            return url
        }
        let resolved = try FolderBookmark.decode(data)
        if resolved.stale { try setDefault(resolved.url) }
        return resolved.url
    }
    public func setDefault(_ url: URL) throws {
        let access = FolderAccess(url)
        defer { withExtendedLifetime(access) {} }
        defaults.set(try FolderBookmark.encode(url), forKey: Self.bookmarkKey)
    }
    public func accept(_ request: ExportRequest) throws {
        if request.makeDefault { try setDefault(request.destination) }
    }
}

/// A copy onto a volume without hard links failed midway. The partial file is left in place
/// (deleting could remove another writer's file), so the user is told where it is.
public struct PartialExportError: Error, CustomStringConvertible {
    public let path: String
    public let underlying: String
    public var description: String {
        "Export failed: a partial file was left at \(path). Delete it before exporting again. (\(underlying))"
    }
}

public enum ExportError: Error { case missingDestination, invalidFilename, invalidDimensions, encodingFailed, sourceWouldBeOverwritten }
