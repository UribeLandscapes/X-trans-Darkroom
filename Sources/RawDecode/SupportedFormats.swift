import Foundation
import UniformTypeIdentifiers

public enum SupportedFormats {
    public static let raw: Set<String> = ["raf", "cr2", "cr3", "crw", "dng"]
    public static let rendered: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "png"]
    public static let all = raw.union(rendered)
    public static func isRaw(_ ext: String) -> Bool { raw.contains(ext.lowercased()) }
    public static func contains(_ url: URL) -> Bool { all.contains(url.pathExtension.lowercased()) }
    public static var contentTypes: [UTType] { all.sorted().compactMap { UTType(filenameExtension: $0) } }
}

public struct CameraSource: Sendable, Equatable {
    public enum Brand: Sendable { case fujifilm, canon, apple, other }
    public let brand: Brand
    public let isRaw: Bool
    // Single eligibility rule for camera controls, recipe application and attribution.
    public let isFujifilmRAF: Bool
    public static let recipeHelp = "Recipes apply only to Fujifilm RAF files"

    public init(extension ext: String = "", make: String = "", hasRAFMagic: Bool = false) {
        let make = make.uppercased()
        brand = make.contains("FUJIFILM") ? .fujifilm : make.contains("CANON") ? .canon : make.contains("APPLE") ? .apple : .other
        isRaw = SupportedFormats.isRaw(ext)
        isFujifilmRAF = ext.lowercased() == "raf" && (brand == .fujifilm || hasRAFMagic)
    }

    public static func read(_ url: URL, make: String = "") -> Self {
        var magic = false
        if url.pathExtension.lowercased() == "raf", let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            magic = (try? handle.read(upToCount: 15)) == Data("FUJIFILMCCD-RAW".utf8)
        }
        return Self(extension: url.pathExtension, make: make, hasRAFMagic: magic)
    }

    public func usesBuiltInLensCorrection(supported: Bool, enabled: Bool) -> Bool {
        isRaw && !isFujifilmRAF && supported && enabled
    }
    public func needsEmbeddedPreview(filterAvailable: Bool, outputAvailable: Bool) -> Bool {
        isRaw && (!filterAvailable || !outputAvailable)
    }
}
