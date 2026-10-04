import Foundation
import CoreImage
import ImagingCore
import EditModel
import ImageCanvas

/// Highlights, Whites and Blacks behaviour, measured on synthetic ramps and patches.
///
/// These sliders had two defects: negative Highlights was a no-op (and positive darkened,
/// the opposite of Lightroom), and Whites/Blacks were a hard clamp that flattened detail.
enum LightToneChecks {

    private static let context = CIContext(options: [
        .workingColorSpace: WorkingColorSpace.linearWide
    ])
    private static let rampWidth = 256
    private static let readSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    /// A horizontal ramp of `rampWidth` strictly increasing sRGB-encoded levels, 4px tall.
    static func ramp() -> CIImage {
        var bytes = [UInt8]()
        for _ in 0..<4 {
            for x in 0..<rampWidth { bytes += [UInt8(x), UInt8(x), UInt8(x), 255] }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: rampWidth * 4,
                       size: CGSize(width: rampWidth, height: 4), format: .RGBA8,
                       colorSpace: WorkingColorSpace.sRGB)
    }

    /// Red channel of the bottom row, unclamped float, in extended sRGB encoding.
    static func readRow(_ image: CIImage) -> [Float] {
        var out = [Float](repeating: 0, count: rampWidth * 4 * 4)
        context.render(image, toBitmap: &out, rowBytes: rampWidth * 16,
                       bounds: CGRect(x: 0, y: 0, width: rampWidth, height: 4),
                       format: .RGBAf, colorSpace: readSpace)
        return (0..<rampWidth).map { out[$0 * 4] }
    }

    static func level(_ stack: EditStack, _ encoded: Double) -> Double {
        let image = RenderChecks.input(RenderChecks.solid(encoded))
        let rendered = RenderPipeline().render(image, stack: stack, proxyRatio: 1)
        return RenderChecks.sample(rendered).r
    }

    static func renderRamp(_ stack: EditStack) -> [Float] {
        readRow(RenderPipeline().render(RenderChecks.input(ramp()), stack: stack, proxyRatio: 1))
    }

    static func strictlyIncreasing(_ row: [Float]) -> Bool {
        zip(row, row.dropFirst()).allSatisfy { $1 > $0 + 1e-6 }
    }

    static func run(_ c: Checks) {
        c.suite("Highlights (recover and brighten)") { c in
            let bright = 0.8, shadow = 0.1, mid = 0.45
            func stack(_ h: Double) -> EditStack { var s = EditStack(); s.light.highlights = h; return s }
            let base = (bright: level(stack(0), bright), shadow: level(stack(0), shadow), mid: level(stack(0), mid))

            let recoverBright = level(stack(-100), bright)
            c.expect(recoverBright < base.bright - 10,
                     "negative Highlights darkens bright pixels (\(Int(base.bright)) -> \(Int(recoverBright)))")
            c.expect(abs(level(stack(-100), shadow) - base.shadow) <= 1,
                     "negative Highlights leaves shadows alone")
            c.expect(abs(level(stack(-100), mid) - base.mid) <= 3,
                     "negative Highlights leaves middle tones nearly alone")

            let boosted = level(stack(100), bright)
            c.expect(boosted > base.bright + 5,
                     "positive Highlights brightens bright pixels (\(Int(base.bright)) -> \(Int(boosted)))")
            c.expect(abs(level(stack(100), shadow) - base.shadow) <= 1,
                     "positive Highlights leaves shadows alone")

            let sweep = [-100.0, -50, 0, 50, 100].map { level(stack($0), bright) }
            c.expect(zip(sweep, sweep.dropFirst()).allSatisfy { $1 > $0 },
                     "Highlights is monotonic across -100...+100 on a bright patch: \(sweep)")

            let identity = renderRamp(stack(0))
            let neutral = renderRamp(EditStack())
            c.expect(identity == neutral, "Highlights 0 is exact identity")

            for h in [-100.0, 100] {
                c.expect(strictlyIncreasing(renderRamp(stack(h))),
                         "ramp stays strictly increasing at Highlights \(Int(h))")
            }
        }

        c.suite("Whites and Blacks (endpoint remap, no clipping)") { c in
            func stack(whites: Double = 0, blacks: Double = 0) -> EditStack {
                var s = EditStack(); s.light.whites = whites; s.light.blacks = blacks; return s
            }
            let neutral = renderRamp(EditStack())
            c.expect(renderRamp(stack()) == neutral, "Whites/Blacks 0 is exact identity")

            for (w, b) in [(100.0, 0.0), (-100, 0), (0, 100), (0, -100), (100, -100), (-100, 100)] {
                let row = renderRamp(stack(whites: w, blacks: b))
                c.expect(strictlyIncreasing(row),
                         "ramp strictly increasing, no plateau at whites \(Int(w)) blacks \(Int(b))")
                c.expect(row.allSatisfy { $0.isFinite }, "finite output at whites \(Int(w)) blacks \(Int(b))")
            }

            let nearWhite = 0.9, nearBlack = 0.06, mid = 0.46
            let baseWhite = level(stack(), nearWhite), baseBlack = level(stack(), nearBlack)
            c.expect(level(stack(whites: 100), nearWhite) > baseWhite, "positive Whites brightens whites")
            c.expect(level(stack(whites: -100), nearWhite) < baseWhite, "negative Whites lowers whites")
            c.expect(level(stack(blacks: -100), nearBlack) < baseBlack, "negative Blacks deepens blacks")
            c.expect(level(stack(blacks: 100), nearBlack) > baseBlack, "positive Blacks lifts blacks")

            let baseMid = level(stack(), mid)
            for (w, b) in [(100.0, 0.0), (-100, 0), (0, 100), (0, -100)] {
                let shift = abs(level(stack(whites: w, blacks: b), mid) - baseMid)
                c.expect(shift <= 6, "middle grey stable at whites \(Int(w)) blacks \(Int(b)) (shift \(shift))")
            }
        }
    }
}
