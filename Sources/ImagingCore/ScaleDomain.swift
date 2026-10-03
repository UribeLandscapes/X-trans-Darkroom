import Foundation

/// Build plan §2: the dual-resolution trap.
///
/// The interactive proxy render runs at a fraction of full resolution. Any adjustment
/// whose parameter is measured in *pixels* (sharpening radius, noise-reduction detail,
/// grain size, lens distortion in absolute units) means something different at 4 MP than
/// at 40 MP. Rendering the proxy with the same numeric value produces a preview that lies.
///
/// Every adjustment parameter therefore declares its domain, and the renderer scales
/// pixel-domain values by the proxy ratio automatically. This is a property of the
/// parameter definition, not something each call site has to remember.
public enum ScaleDomain: String, Codable, Sendable {
    /// Value is independent of image size (exposure EV, saturation %, hue degrees).
    case invariant
    /// Value is in pixels at full resolution; multiply by proxy ratio for the proxy render.
    case pixels
    /// Value is a fraction of the image diagonal; already resolution independent.
    case normalized
}

/// A single adjustment parameter with its neutral value and scaling behaviour.
public struct Parameter: Sendable, Equatable {
    public let key: String
    public let range: ClosedRange<Double>
    public let neutral: Double
    public let domain: ScaleDomain

    public init(key: String, range: ClosedRange<Double>, neutral: Double, domain: ScaleDomain = .invariant) {
        self.key = key
        self.range = range
        self.neutral = neutral
        self.domain = domain
    }

    /// Resolve this parameter's value for a render at `proxyRatio` (1.0 = full resolution).
    public func resolved(_ value: Double, proxyRatio: Double) -> Double {
        switch domain {
        case .invariant, .normalized: return value
        case .pixels: return value * proxyRatio
        }
    }

    public func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
