import Foundation

public struct CustomAdjustments: Codable, Equatable, Sendable {
    public var glowAmount: Double = 0    // Opacity, 0...100.
    /// Pixel domain: full-resolution pixels, 1...250; must scale with proxyRatio (§2).
    public var glowRadius: Double = 60

    public static let neutral = CustomAdjustments()
    public init() {}

    private enum CodingKeys: String, CodingKey { case glowAmount, glowRadius }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glowAmount = c.value(.glowAmount, 0)
        glowRadius = c.value(.glowRadius, 60)
    }
}
