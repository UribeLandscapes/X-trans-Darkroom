import Foundation

public struct ProfileLibrary: Sendable {
    public let bundledDirectory: URL?
    public let userDirectory: URL
    public private(set) var profiles: [CameraProfile] = []

    public init(bundledDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Profiles"),
                userDirectory: URL = URL.applicationSupportDirectory.appendingPathComponent("XTransDarkroom/Profiles")) {
        self.bundledDirectory = bundledDirectory; self.userDirectory = userDirectory
        reload()
    }

    public mutating func reload() {
        var found: [String: CameraProfile] = [:]
        for directory in [bundledDirectory, userDirectory].compactMap({ $0 }) {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "dcp" {
                if let profile = DCPParser.read(from: url) { found[profile.identifier] = profile }
            }
        }
        profiles = found.values.sorted {
            $0.displayName == $1.displayName ? $0.identifier < $1.identifier : $0.displayName < $1.displayName
        }
    }

    public func profiles(for cameraModel: String) -> [CameraProfile] {
        let model = Self.normalized(cameraModel)
        guard !model.isEmpty else { return [] }
        // An absent restriction is not evidence that a camera-specific look fits every sensor.
        return profiles.filter { $0.cameraModel.map(Self.normalized) == model }
    }

    public func resolve(identifier: String, cameraModel: String) -> CameraProfile? {
        let matching = profiles(for: cameraModel)
        if !identifier.isEmpty, let selected = matching.first(where: { $0.identifier == identifier }) {
            return selected
        }
        // A missing selection must not silently substitute a film look.
        return matching.first {
            ($0.colorMatrix1 != nil || $0.forwardMatrix1 != nil) &&
            $0.profileHueSatMap1 == nil && $0.profileHueSatMap2 == nil && $0.profileLookTable == nil &&
            ($0.profileToneCurve == nil || $0.profileToneCurve!.isIdentity)
        }
    }

    @discardableResult
    public mutating func importProfile(from url: URL) throws -> CameraProfile {
        guard url.pathExtension.lowercased() == "dcp", let data = try? Data(contentsOf: url),
              let profile = DCPParser.parse(data) else { throw ImportError.invalidProfile }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        // Content identity survives renames and prevents duplicate imports or filename collisions.
        try data.write(to: userDirectory.appendingPathComponent(profile.identifier + ".dcp"), options: .atomic)
        reload()
        return profile
    }

    public enum ImportError: Error { case invalidProfile }
    private static func normalized(_ model: String) -> String {
        model.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
