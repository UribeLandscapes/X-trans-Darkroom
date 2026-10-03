import Foundation
import CoreGraphics

/// Build plan, assumption 4: the internal working space is scene-linear and wide-gamut.
/// Decode lands here, every adjustment operates here, and only the final output transform
/// converts to a display or export space.
public enum WorkingColorSpace {
    /// Linear Rec. 2020 primaries, used for all intermediate computation.
    public static var linearWide: CGColorSpace {
        CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ?? CGColorSpaceCreateDeviceRGB()
    }

    public static var sRGB: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    public static var displayP3: CGColorSpace {
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    }

    public static var adobeRGB: CGColorSpace {
        CGColorSpace(name: CGColorSpace.adobeRGB1998) ?? CGColorSpaceCreateDeviceRGB()
    }
}

/// Export-side colour space choice (Build plan §8).
public enum OutputColorSpace: String, Codable, CaseIterable, Sendable {
    case sRGB, displayP3, adobeRGB

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB (1998)"
        }
    }

    public var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return WorkingColorSpace.sRGB
        case .displayP3: return WorkingColorSpace.displayP3
        case .adobeRGB: return WorkingColorSpace.adobeRGB
        }
    }
}
