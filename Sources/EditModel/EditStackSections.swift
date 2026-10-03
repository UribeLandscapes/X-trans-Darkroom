import Foundation
import CryptoKit

public enum EditStackSection: String, CaseIterable, Sendable {
    case light = "Light", curve = "Curve", color = "Color", mix = "Mix"
    case effects = "Effects", detail = "Detail", geometry = "Geometry", optics = "Optics"
    case custom = "Custom", profileCamera = "Profile & Camera"
}
public typealias EditStackSections = Set<EditStackSection>
public extension Set where Element == EditStackSection {
    static var all: Self { Set(EditStackSection.allCases) }
    static var standard: Self { all.subtracting([.geometry]) }
}
public extension EditStack {
    var settingsHash: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    /// Source identity and attribution belong to the destination, never the clipboard.
    func merging(_ source: EditStack, sections: EditStackSections) -> EditStack {
        var result = self
        for section in sections {
            switch section {
            case .light: result.light = source.light
            case .curve: result.curves = source.curves
            case .color: result.color = source.color
            case .mix: result.hsl = source.hsl; result.grading = source.grading
            case .effects: result.effects = source.effects
            case .detail: result.detail = source.detail
            case .geometry: result.geometry = source.geometry
            case .optics: result.optics = source.optics
            case .custom: result.custom = source.custom
            case .profileCamera: result.profileID = source.profileID; result.cameraSettings = source.cameraSettings
            }
        }
        return result
    }
}
