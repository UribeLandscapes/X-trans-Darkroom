import Foundation
import CoreImage
import EditModel
import ImageCanvas
import RawDecode
import ImagingCore

/// Regression checks for the shared-cache data races (ColorCubeCache, LensCorrectionFilter)
/// and the warp ROI margin.
enum CacheRaceChecks {
    private static let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])

    /// Float render in an extended colour space, so neither gain >= 1 nor a dark input clips.
    private static func render(_ image: CIImage) -> [Float] {
        let r = image.extent
        var px = [Float](repeating: 0, count: Int(r.width) * Int(r.height) * 4)
        px.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(r.width) * 16, bounds: r,
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return px
    }

    private static func darkGrey(_ w: Int, _ h: Int) -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, colorSpace: WorkingColorSpace.sRGB)!)
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    static func run(_ c: Checks) {
        c.suite("Cache races: ColorCubeCache under concurrent use") { c in
            var mixA = HSLMix(); var bandA = HSLBand(); bandA.hue = 30; bandA.saturation = 40; mixA[.red] = bandA
            var mixB = HSLMix(); var bandB = HSLBand(); bandB.hue = -40; bandB.saturation = -30; bandB.luminance = 20; mixB[.blue] = bandB
            var gradeA = ColorGrading(); gradeA.shadowSaturation = 40; gradeA.shadowHue = 200
            var gradeB = ColorGrading(); gradeB.highlightSaturation = 50; gradeB.highlightHue = 30
            let inputs: [(HSLMix, ColorGrading)] = [(mixA, gradeA), (mixB, gradeB)]
            let expected = inputs.map { ColorCubeCache.build(mix: $0.0, grading: $0.1, dimension: 17) }
            c.expect(expected[0] != expected[1], "the two test inputs produce distinct cubes")

            let rounds = 30, perRound = 400
            let iterations = rounds * perRound
            let mismatches = Counter()
            for _ in 0..<rounds {
                let cache = ColorCubeCache()   // fresh each round so the cold-start race is hit too
                DispatchQueue.concurrentPerform(iterations: perRound) { i in
                    let k = i % 2
                    if cache.cube(for: inputs[k].0, grading: inputs[k].1) != expected[k] { mismatches.add() }
                }
            }
            c.expect(mismatches.value == 0,
                     "every concurrent cube equals the serial build for its own input (\(mismatches.value) wrong of \(iterations))")
        }

        c.suite("Cache races: LensCorrectionFilter gain cache under concurrent use") { c in
            let knots = (0...8).map { Double($0) / 8 }
            func table(_ f: @escaping (Double) -> Double) -> FujiLensCorrection {
                FujiLensCorrection(
                    knots: knots, distortion: knots.map { _ in 0 },
                    chromaticRed: knots.map { _ in 0 }, chromaticBlue: knots.map { _ in 0 },
                    vignetting: knots.map(f))
            }
            // Two distinct tables, each used at two extents: four cache keys contending.
            let tables = [table { 100 - 60 * $0 * $0 }, table { 100 - 20 * $0 }]
            let sizes = [(300, 200), (240, 260)]
            let cases = tables.indices.flatMap { t in sizes.indices.map { (t, $0) } }
            func apply(_ f: LensCorrectionFilter, _ k: Int) -> CIImage {
                let (t, s) = cases[k]
                return f.apply(darkGrey(sizes[s].0, sizes[s].1), correction: tables[t],
                               distortion: false, vignetting: true, chromaticAberration: false)
            }
            let serial = LensCorrectionFilter()
            let expected = cases.indices.map { render(apply(serial, $0)) }
            let input = sizes.map { render(darkGrey($0.0, $0.1)) }
            for k in cases.indices {
                c.expect(expected[k] != input[cases[k].1], "case \(k): the correction changes pixels (not a pass-through)")
            }
            c.expect(expected[0] != expected[2] && expected[1] != expected[3],
                     "the two vignetting tables give distinct output at the same extent")

            let rounds = 10, perRound = 200
            let iterations = rounds * perRound
            var bad = 0
            for _ in 0..<rounds {
                let filter = LensCorrectionFilter()   // fresh each round: cold lazy kernels + empty cache
                let results = ResultBox(count: perRound)
                DispatchQueue.concurrentPerform(iterations: perRound) { i in
                    results.set(i, apply(filter, i % cases.count))
                }
                for i in 0..<perRound {
                    let image = results.get(i)!
                    let k = i % cases.count
                    let size = sizes[cases[k].1]
                    if image.extent.size != CGSize(width: size.0, height: size.1)
                        || render(image) != expected[k] { bad += 1 }
                }
            }
            c.expect(bad == 0, "every concurrent result matches the serial render (\(bad) wrong of \(iterations))")
        }

        c.suite("Warp ROI margin covers the polynomial displacement") { c in
            let halfDiagonal = (7728.0 * 7728.0 + 5152.0 * 5152.0).squareRoot() / 2
            let strong = FujiLensCorrection.RadialPolynomial(k1: 0.05, k2: 0, k3: 0)
            let margin = LensCorrectionFilter.warpMargin(poly: strong, halfDiagonal: halfDiagonal)
            let cornerDisplacement = 0.05 * halfDiagonal   // |r * k1 r^2| at r = 1
            c.expect(margin > 32, "strong polynomial margin exceeds the old fixed 32 (\(margin))")
            c.expect(Double(margin) >= cornerDisplacement,
                     "margin \(margin) covers the corner displacement \(cornerDisplacement)")

            let zero = FujiLensCorrection.RadialPolynomial(k1: 0, k2: 0, k3: 0)
            c.expect(LensCorrectionFilter.warpMargin(poly: zero, halfDiagonal: halfDiagonal) == 32,
                     "zero polynomial keeps the 32 floor")
            let mixed = FujiLensCorrection.RadialPolynomial(k1: -0.03, k2: 0.04, k3: -0.02)
            let m2 = LensCorrectionFilter.warpMargin(poly: mixed, halfDiagonal: halfDiagonal)
            let worst = stride(from: 0.0, through: 1.0, by: 0.01).map {
                abs($0 * (mixed.k1 * $0 * $0 + mixed.k2 * pow($0, 4) + mixed.k3 * pow($0, 6)))
            }.max()! * halfDiagonal
            c.expect(Double(m2) >= worst, "sign-mixed polynomial margin \(m2) covers max displacement \(worst)")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CIImage?]
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ v: CIImage) { lock.lock(); items[i] = v; lock.unlock() }
    func get(_ i: Int) -> CIImage? { lock.lock(); defer { lock.unlock() }; return items[i] }
}
