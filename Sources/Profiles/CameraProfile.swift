import Foundation
import EditModel

public struct ProfileMatrix: Sendable, Equatable {
    public let elements: [Double]
    public init?(_ elements: [Double]) {
        guard elements.count == 9, elements.allSatisfy(\.isFinite) else { return nil }
        self.elements = elements
    }
    public static let identity = ProfileMatrix([1, 0, 0, 0, 1, 0, 0, 0, 1])!
    public func applied(to value: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>((0..<3).map { row in
            (0..<3).reduce(0.0) { $0 + elements[row * 3 + $1] * value[$1] }
        })
    }
    public func interpolated(to other: Self, weight: Double) -> Self {
        if weight <= 0 { return self }
        if weight >= 1 { return other }
        return Self(zip(elements, other.elements).map { $0 + ($1 - $0) * weight })!
    }
}

/// DCP data is saturation-fastest, then hue, then value. Shifts are degrees;
/// saturation and value entries are multiplicative scales, not output coordinates.
public struct ProfileGrid: Sendable, Equatable {
    public let hueDivisions: Int
    public let saturationDivisions: Int
    public let valueDivisions: Int
    public let entries: [SIMD3<Double>]
    public init?(hueDivisions h: Int, saturationDivisions s: Int, valueDivisions v: Int,
                 entries: [SIMD3<Double>]) {
        guard h > 0, s > 0, v > 0, h <= entries.count,
              s <= entries.count / h, v <= entries.count / h / s,
              h * s * v == entries.count,
              entries.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        hueDivisions = h; saturationDivisions = s; valueDivisions = v; self.entries = entries
    }
    /// Grid coordinates clamp at edges, allowing inspection of every stored sample.
    /// A future HSV pipeline must handle cyclic hue before mapping to these coordinates.
    public func lookup(hue: Double, saturation: Double, value: Double) -> SIMD3<Double> {
        func axis(_ x: Double, _ n: Int) -> (Int, Int, Double) {
            let p = x.isNaN ? 0 : min(max(x, 0), Double(n - 1))
            let lo = Int(p)
            return (lo, min(lo + 1, n - 1), p - Double(lo))
        }
        let axes = [axis(hue, hueDivisions), axis(saturation, saturationDivisions), axis(value, valueDivisions)]
        var result = SIMD3<Double>.zero
        for corner in 0..<8 {
            var indices = [Int](); var weight = 1.0
            for a in 0..<3 {
                let upper = corner & (1 << a) != 0
                indices.append(upper ? axes[a].1 : axes[a].0)
                weight *= upper ? axes[a].2 : 1 - axes[a].2
            }
            result += entries[(indices[2] * hueDivisions + indices[0]) * saturationDivisions + indices[1]] * weight
        }
        return result
    }
}

public struct CameraProfile: Sendable, Equatable {
    public var identifier: String
    public var displayName: String
    public var cameraModel: String?
    public var profileCalibrationSignature: String?
    public var colorMatrix1: ProfileMatrix?
    public var colorMatrix2: ProfileMatrix?
    public var forwardMatrix1: ProfileMatrix?
    public var forwardMatrix2: ProfileMatrix?
    public var calibrationIlluminant1: UInt16?
    public var calibrationIlluminant2: UInt16?
    public var profileToneCurve: ToneCurve?
    public var profileHueSatMap1: ProfileGrid?
    public var profileHueSatMap2: ProfileGrid?
    public var profileLookTable: ProfileGrid?
    public var hueSatMapEncoding: UInt32?
    public var lookTableEncoding: UInt32?

    public init(identifier: String, displayName: String, cameraModel: String?) {
        self.identifier = identifier; self.displayName = displayName; self.cameraModel = cameraModel
    }
    public static func neutral(identifier: String = "neutral", cameraModel: String? = nil,
                               matrix: ProfileMatrix = .identity, curve: ToneCurve = .identity) -> Self {
        var result = Self(identifier: identifier, displayName: "Neutral", cameraModel: cameraModel)
        result.colorMatrix1 = matrix; result.profileToneCurve = curve
        return result
    }
    // DNG interpolation is linear in reciprocal temperature, not Kelvin.
    public func illuminantWeight(whiteBalanceKelvin: Double) -> Double? {
        guard whiteBalanceKelvin.isFinite, whiteBalanceKelvin > 0,
              let a = Self.temperature(calibrationIlluminant1),
              let b = Self.temperature(calibrationIlluminant2), a != b else { return nil }
        return min(max((1 / whiteBalanceKelvin - 1 / a) / (1 / b - 1 / a), 0), 1)
    }
    public func colorMatrix(whiteBalanceKelvin: Double) -> ProfileMatrix? {
        interpolate(colorMatrix1, colorMatrix2, kelvin: whiteBalanceKelvin)
    }
    public func forwardMatrix(whiteBalanceKelvin: Double) -> ProfileMatrix? {
        interpolate(forwardMatrix1, forwardMatrix2, kelvin: whiteBalanceKelvin)
    }
    private func interpolate(_ a: ProfileMatrix?, _ b: ProfileMatrix?, kelvin: Double) -> ProfileMatrix? {
        guard let a else { return nil }
        guard let b else { return a }
        guard let weight = illuminantWeight(whiteBalanceKelvin: kelvin) else { return nil }
        return a.interpolated(to: b, weight: weight)
    }
    private static func temperature(_ illuminant: UInt16?) -> Double? {
        switch illuminant {
        case 17, 3: return 2850
        case 18: return 4874
        case 19: return 6774
        case 20: return 5500
        case 21, 1, 4: return 6500
        case 22: return 7500
        case 23: return 5000
        case 9: return 5500
        case 10: return 6500
        case 11: return 7500
        default: return nil // Unknown/custom illuminants need metadata, not a guessed temperature.
        }
    }
}
