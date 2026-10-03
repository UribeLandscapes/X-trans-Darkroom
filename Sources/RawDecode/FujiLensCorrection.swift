import Foundation

/// Build plan §6: lens correction data read straight out of the RAF.
///
/// Fujifilm cameras write per-shot distortion, chromatic aberration and vignetting tables
/// into the file for whatever XF/XC lens is mounted. That is why §6's primary path needs no
/// profile database: **discontinued Fujinon lenses are covered identically to current ones**,
/// and zoom position and focus distance are already baked in, which a static Lensfun entry
/// cannot represent.
///
/// Container layout, established by probing a real X-T5 RAF:
/// ```
/// RAF header
///   bytes 100..103 (big-endian u32) -> CFA offset
/// CFA offset:
///   "II*\0", u32 = 8            standard little-endian TIFF header
///   +8:  IFD0, 1 entry, tag 0xf000, value = 26 (offset of the real IFD, relative to CFA)
///   +26: FujiIFD, 20 entries    <- 0xf00b, 0xf00f, 0xf010 live here
/// ```
/// All value offsets in that IFD are relative to the CFA offset, and the tables are
/// SRATIONAL (type 10).
public struct FujiLensCorrection: Sendable, Equatable {

    /// Normalized radial positions the tables are sampled at, from centre outwards.
    /// Nine knots, running past 1.0 because the corner of the frame is further from centre
    /// than the edge midpoint.
    public var knots: [Double]

    /// Per-knot geometric distortion, as a percentage displacement.
    public var distortion: [Double]

    /// Per-knot radial scale factors for the red and blue channels, relative to green.
    public var chromaticRed: [Double]
    public var chromaticBlue: [Double]

    /// Per-knot transmission, as a percentage of centre brightness (100 = no falloff).
    public var vignetting: [Double]

    public init(knots: [Double], distortion: [Double], chromaticRed: [Double],
                chromaticBlue: [Double], vignetting: [Double]) {
        self.knots = knots
        self.distortion = distortion
        self.chromaticRed = chromaticRed
        self.chromaticBlue = chromaticBlue
        self.vignetting = vignetting
    }

    public var isEmpty: Bool { knots.isEmpty }

    // MARK: Parsing

    private enum Tag {
        static let distortion: UInt16 = 0xf00b
        static let chromatic: UInt16 = 0xf00f
        static let vignetting: UInt16 = 0xf010
    }

    /// Returns nil when the file is not a RAF, or carries no correction tables (third-party
    /// or adapted glass). The caller falls back to a bundled profile, then to manual sliders.
    public static func read(from url: URL) -> FujiLensCorrection? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 108), header.count == 108,
              header.prefix(15) == Data("FUJIFILMCCD-RAW".utf8) else { return nil }

        let cfaOffset = Int(be32(header, at: 100))
        guard cfaOffset > 0 else { return nil }

        // The tables sit within a few KB of the CFA offset; reading 64 KB covers the IFD and
        // every value it points at without pulling in the 30 MB of sensor data behind them.
        try? handle.seek(toOffset: UInt64(cfaOffset))
        guard let block = try? handle.read(upToCount: 65_536), block.count > 64 else { return nil }

        guard block[0] == 0x49, block[1] == 0x49 else { return nil }  // "II" little-endian

        // IFD0 holds a single entry whose value is the offset of the real FujiIFD.
        let ifd0 = Int(le32(block, at: 4))
        guard ifd0 + 2 <= block.count else { return nil }
        let ifd0Count = Int(le16(block, at: ifd0))
        guard ifd0Count >= 1 else { return nil }
        let subOffset = Int(le32(block, at: ifd0 + 2 + 8))

        guard subOffset + 2 <= block.count else { return nil }
        let count = Int(le16(block, at: subOffset))
        guard count > 0, count < 200 else { return nil }

        var tables: [UInt16: [Double]] = [:]
        for i in 0..<count {
            let entry = subOffset + 2 + i * 12
            guard entry + 12 <= block.count else { break }
            let tag = le16(block, at: entry)
            guard tag == Tag.distortion || tag == Tag.chromatic || tag == Tag.vignetting else { continue }
            let type = le16(block, at: entry + 2)
            let n = Int(le32(block, at: entry + 4))
            let valueOffset = Int(le32(block, at: entry + 8))
            guard type == 10 || type == 5, n > 0, n < 256 else { continue }   // (S)RATIONAL
            guard valueOffset + n * 8 <= block.count else { continue }

            var values: [Double] = []
            values.reserveCapacity(n)
            for k in 0..<n {
                let at = valueOffset + k * 8
                if type == 10 {
                    let num = Int32(bitPattern: le32(block, at: at))
                    let den = Int32(bitPattern: le32(block, at: at + 4))
                    values.append(den == 0 ? 0 : Double(num) / Double(den))
                } else {
                    let num = le32(block, at: at), den = le32(block, at: at + 4)
                    values.append(den == 0 ? 0 : Double(num) / Double(den))
                }
            }
            tables[tag] = values
        }

        // Layout, consistent across all three tables: [0] is a scale value, [1...9] are the
        // nine shared radial knots, and the remainder are per-knot data.
        guard let d = tables[Tag.distortion], d.count >= 19,
              let v = tables[Tag.vignetting], v.count >= 19 else { return nil }

        let knots = Array(d[1..<10])
        var red = [Double](repeating: 1, count: 9)
        var blue = [Double](repeating: 1, count: 9)
        if let ca = tables[Tag.chromatic], ca.count >= 28 {
            // CA is stored as additive radial offsets; 1 + offset gives a scale factor.
            red = ca[10..<19].map { 1 + $0 }
            blue = ca[19..<28].map { 1 + $0 }
        }

        return FujiLensCorrection(
            knots: knots,
            distortion: Array(d[10..<19]),
            chromaticRed: red,
            chromaticBlue: blue,
            vignetting: Array(v[10..<19]))
    }

    // MARK: Sampling

    /// Linear interpolation across the knot table, clamped at both ends.
    public static func sample(_ table: [Double], knots: [Double], at r: Double) -> Double {
        guard !table.isEmpty, table.count == knots.count else { return 0 }
        if r <= knots[0] { return table[0] }
        if r >= knots[knots.count - 1] { return table[table.count - 1] }
        for i in 0..<(knots.count - 1) where r >= knots[i] && r <= knots[i + 1] {
            let span = knots[i + 1] - knots[i]
            let t = span > 0 ? (r - knots[i]) / span : 0
            return table[i] + (table[i + 1] - table[i]) * t
        }
        return table[table.count - 1]
    }

    public func distortionScale(atRadius r: Double) -> Double {
        1 + Self.sample(distortion, knots: knots, at: r) / 100
    }

    /// Gain that cancels the lens's falloff: 100/transmission.
    public func vignettingGain(atRadius r: Double) -> Double {
        let transmission = Self.sample(vignetting, knots: knots, at: r)
        return transmission > 1 ? 100 / transmission : 1
    }

    public func redScale(atRadius r: Double) -> Double { Self.sample(chromaticRed, knots: knots, at: r) }
    public func blueScale(atRadius r: Double) -> Double { Self.sample(chromaticBlue, knots: knots, at: r) }

    /// Sampled lookup tables for the GPU, indexed by normalized radius 0...`maxRadius`.
    public func gainTable(resolution: Int = 128, maxRadius: Double = 1.2) -> [Float] {
        (0..<resolution).map {
            Float(vignettingGain(atRadius: Double($0) / Double(resolution - 1) * maxRadius))
        }
    }

    // MARK: Polynomial fitting

    /// Radial polynomial coefficients, the model every lens-correction pipeline uses:
    ///     r' = r * (1 + k1·r² + k2·r⁴ + k3·r⁶)
    ///
    /// A GPU warp kernel cannot carry a nine-entry lookup table, so the knot table is fitted
    /// to this cubic-in-r² form on the CPU and only three floats cross into the shader.
    /// Fitted, not guessed: the residual is asserted in the checks.
    public struct RadialPolynomial: Sendable, Equatable {
        public var k1: Double, k2: Double, k3: Double
        public init(k1: Double, k2: Double, k3: Double) {
            self.k1 = k1
            self.k2 = k2
            self.k3 = k3
        }
        public static let identity = RadialPolynomial(k1: 0, k2: 0, k3: 0)
        public func scale(atRadius r: Double) -> Double {
            let r2 = r * r
            return 1 + k1 * r2 + k2 * r2 * r2 + k3 * r2 * r2 * r2
        }
    }

    /// Least-squares fit of `values` (as multiplicative scales) over `knots`.
    static func fit(scales: [Double], knots: [Double]) -> RadialPolynomial {
        guard scales.count == knots.count, knots.count >= 3 else { return .identity }
        // Design matrix columns are r², r⁴, r⁶; the target is (scale - 1).
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var atb = [Double](repeating: 0, count: 3)
        for (i, r) in knots.enumerated() {
            let r2 = r * r
            let basis = [r2, r2 * r2, r2 * r2 * r2]
            let target = scales[i] - 1
            for a in 0..<3 {
                atb[a] += basis[a] * target
                for b in 0..<3 { ata[a][b] += basis[a] * basis[b] }
            }
        }
        // Gaussian elimination with partial pivoting - a 3x3 solve, no library needed.
        for col in 0..<3 {
            var pivot = col
            for row in (col + 1)..<3 where abs(ata[row][col]) > abs(ata[pivot][col]) { pivot = row }
            if abs(ata[pivot][col]) < 1e-18 { return .identity }
            if pivot != col { ata.swapAt(pivot, col); atb.swapAt(pivot, col) }
            for row in (col + 1)..<3 {
                let f = ata[row][col] / ata[col][col]
                for k in col..<3 { ata[row][k] -= f * ata[col][k] }
                atb[row] -= f * atb[col]
            }
        }
        var x = [Double](repeating: 0, count: 3)
        for row in stride(from: 2, through: 0, by: -1) {
            var sum = atb[row]
            for k in (row + 1)..<3 { sum -= ata[row][k] * x[k] }
            x[row] = sum / ata[row][row]
        }
        return RadialPolynomial(k1: x[0], k2: x[1], k3: x[2])
    }

    /// Distortion as a warp polynomial. The table is a percentage displacement, so a
    /// positive value means the image is stretched outward there and must be pulled back in.
    public var distortionPolynomial: RadialPolynomial {
        Self.fit(scales: distortion.map { 1 + $0 / 100 }, knots: knots)
    }

    public var redPolynomial: RadialPolynomial { Self.fit(scales: chromaticRed, knots: knots) }
    public var bluePolynomial: RadialPolynomial { Self.fit(scales: chromaticBlue, knots: knots) }

    /// Worst-case fit error across the knots, as a fraction. Used to prove the polynomial
    /// actually represents the table rather than merely compiling.
    public func fitResidual(_ poly: RadialPolynomial, scales: [Double]) -> Double {
        var worst = 0.0
        for (i, r) in knots.enumerated() {
            worst = max(worst, abs(poly.scale(atRadius: r) - scales[i]))
        }
        return worst
    }

    // MARK: Byte helpers

    private static func le16(_ d: Data, at i: Int) -> UInt16 {
        UInt16(d[d.startIndex + i]) | UInt16(d[d.startIndex + i + 1]) << 8
    }
    private static func le32(_ d: Data, at i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(d[d.startIndex + i + k]) << (8 * k) }
        return v
    }
    private static func be32(_ d: Data, at i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v = (v << 8) | UInt32(d[d.startIndex + i + k]) }
        return v
    }
}
