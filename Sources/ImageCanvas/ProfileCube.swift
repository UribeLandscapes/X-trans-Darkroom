import Foundation
import Synchronization
import EditModel
import Profiles

public final class ProfileCubeCache: Sendable {
    public enum Kind: Sendable { case hueSat, look }
    public static let dimension = 33
    private struct Entry: Sendable {
        let profile: CameraProfile
        let kind: Kind
        let weight: Double
        let data: Data
    }
    private struct State: Sendable {
        var entries: [Entry] = []
        var rebuilds = 0
    }
    private let state = Mutex(State())
    public init() {}
    public var rebuildCount: Int { state.withLock { $0.rebuilds } }

    public func cube(for profile: CameraProfile, kind: Kind, kelvin: Double) -> Data? {
        guard let first = kind == .look ? profile.profileLookTable : profile.profileHueSatMap1 else { return nil }
        let second = kind == .hueSat ? profile.profileHueSatMap2 : nil
        let weight = second == nil ? 0 : (profile.illuminantWeight(whiteBalanceKelvin: kelvin) ?? 0)
        let encoding = kind == .look ? profile.lookTableEncoding : profile.hueSatMapEncoding
        return state.withLock { state in
            // Include content as well as identity: callers can construct mutable profiles,
            // and WB can change a dual-illuminant deformation without changing its ID.
            if let hit = state.entries.first(where: { $0.profile == profile && $0.kind == kind && $0.weight == weight }) {
                return hit.data
            }
            let data = Self.build(first, second: second, weight: weight, encoded: encoding == 1)
            // Bound memory while retaining recent profiles for A/B comparisons.
            if state.entries.count >= 16 { state.entries.removeFirst() }
            state.entries.append(Entry(profile: profile, kind: kind, weight: weight, data: data))
            state.rebuilds += 1
            return data
        }
    }

    private static func build(_ first: ProfileGrid, second: ProfileGrid?, weight: Double, encoded: Bool) -> Data {
        func encode(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        func decode(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        func lookup(_ grid: ProfileGrid, h: Double, s: Double, v: Double) -> SIMD3<Double> {
            // The last hue cell interpolates back to zero, avoiding a red seam.
            let hue = h / 360 * Double(grid.hueDivisions)
            let lo = floor(hue)
            let a = grid.lookup(hue: lo, saturation: s * Double(grid.saturationDivisions - 1), value: v * Double(grid.valueDivisions - 1))
            let b = grid.lookup(hue: Double((Int(lo) + 1) % grid.hueDivisions), saturation: s * Double(grid.saturationDivisions - 1), value: v * Double(grid.valueDivisions - 1))
            return a + (b - a) * (hue - lo)
        }
        let n = dimension
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let (h, s, v) = HSV.fromRGB(Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
            let tableValue = encoded ? encode(v) : v
            var shift = lookup(first, h: h, s: s, v: tableValue)
            if let second { shift += (lookup(second, h: h, s: s, v: tableValue) - shift) * weight }
            var hue = (h + shift.x).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            let value = max(0, tableValue * shift.z)
            let rgb = HSV.toRGB(hue, min(max(s * shift.y, 0), 1), encoded ? decode(value) : value)
            values.append(contentsOf: [Float(rgb.0), Float(rgb.1), Float(rgb.2), 1])
        } } }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
