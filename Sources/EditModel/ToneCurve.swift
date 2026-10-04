import Foundation

/// Build plan §3, Phase 3: the tone curve.
///
/// Interpolation is monotone cubic (Fritsch–Carlson), not a natural cubic spline. A natural
/// spline overshoots between control points, which on a tone curve means a curve the user
/// drew as increasing can locally *decrease* — visible as posterized reversals in gradients.
/// Monotone cubic is the standard choice in photo editors for exactly this reason.
public struct ToneCurve: Codable, Equatable, Sendable {

    /// Control points in unit coordinates, sorted by x. Always includes the two endpoints.
    public var points: [Point]

    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public static let identity = ToneCurve(points: [
        Point(x: 0, y: 0), Point(x: 1, y: 1)
    ])

    public init(points: [Point]) {
        self.points = points.sorted { $0.x < $1.x }
    }

    private enum CodingKeys: String, CodingKey { case points }
    /// Missing or null `points` is the identity curve; a present but malformed value throws.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try c.decodeIfPresent([Point].self, forKey: .points) ?? Self.identity.points)
    }

    public var isIdentity: Bool { self == .identity }

    // MARK: Editing

    /// Insert a control point, replacing any existing point at effectively the same x.
    public func adding(_ point: Point) -> ToneCurve {
        var next = points.filter { abs($0.x - point.x) > 0.004 }
        next.append(point)
        return ToneCurve(points: next)
    }

    /// Endpoints are never removable — a curve without them is undefined.
    public func removing(at index: Int) -> ToneCurve {
        guard points.indices.contains(index), index != 0, index != points.count - 1 else { return self }
        var next = points
        next.remove(at: index)
        return ToneCurve(points: next)
    }

    public func moving(index: Int, to point: Point) -> ToneCurve {
        guard points.indices.contains(index) else { return self }
        var next = points
        // Endpoints keep their x pinned so the curve always spans the full range.
        let isEndpoint = index == 0 || index == points.count - 1
        next[index] = Point(x: isEndpoint ? next[index].x : min(max(point.x, 0), 1),
                            y: min(max(point.y, 0), 1))
        return ToneCurve(points: next)
    }

    // MARK: Evaluation

    /// Fritsch–Carlson monotone cubic interpolation, evaluated at `x` in 0...1.
    public func value(at x: Double) -> Double {
        let p = points
        guard p.count > 1 else { return x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }

        // Secant slopes between consecutive points.
        var delta = [Double](repeating: 0, count: p.count - 1)
        for i in 0..<(p.count - 1) {
            let dx = p[i + 1].x - p[i].x
            delta[i] = dx > 0 ? (p[i + 1].y - p[i].y) / dx : 0
        }

        // Tangents, clamped so the interpolant cannot overshoot or reverse.
        var m = [Double](repeating: 0, count: p.count)
        m[0] = delta[0]
        m[p.count - 1] = delta[p.count - 2]
        for i in 1..<(p.count - 1) {
            m[i] = (delta[i - 1] * delta[i] <= 0) ? 0 : (delta[i - 1] + delta[i]) / 2
        }
        for i in 0..<(p.count - 1) where delta[i] == 0 {
            m[i] = 0; m[i + 1] = 0
        }
        for i in 0..<(p.count - 1) where delta[i] != 0 {
            let a = m[i] / delta[i], b = m[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * delta[i]
                m[i + 1] = t * b * delta[i]
            }
        }

        var i = 0
        while i < p.count - 2 && x > p[i + 1].x { i += 1 }
        let h = p[i + 1].x - p[i].x
        guard h > 0 else { return p[i].y }
        let t = (x - p[i].x) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let y = h00 * p[i].y + h10 * h * m[i] + h01 * p[i + 1].y + h11 * h * m[i + 1]
        return min(max(y, 0), 1)
    }

    /// Sampled lookup table for the GPU. 256 entries matches the histogram's bin count and
    /// is ample for 16-bit rendering because the values are interpolated between samples.
    public func lut(resolution: Int = 256) -> [Float] {
        (0..<resolution).map { Float(value(at: Double($0) / Double(resolution - 1))) }
    }
}

/// The four curves of the Tone Curve panel. Composite applies to all channels; the
/// per-channel curves apply after it, matching the order users expect from Lightroom.
public struct ToneCurveSet: Codable, Equatable, Sendable {
    public var composite: ToneCurve = .identity
    public var red: ToneCurve = .identity
    public var green: ToneCurve = .identity
    public var blue: ToneCurve = .identity

    public static let neutral = ToneCurveSet()
    public init() {}

    public var isNeutral: Bool {
        composite.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    private enum CodingKeys: String, CodingKey { case composite, red, green, blue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        composite = (try c.decodeIfPresent(ToneCurve.self, forKey: .composite)) ?? .identity
        red       = (try c.decodeIfPresent(ToneCurve.self, forKey: .red)) ?? .identity
        green     = (try c.decodeIfPresent(ToneCurve.self, forKey: .green)) ?? .identity
        blue      = (try c.decodeIfPresent(ToneCurve.self, forKey: .blue)) ?? .identity
    }
}
