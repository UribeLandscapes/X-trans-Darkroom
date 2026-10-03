import Foundation
import CoreImage
import ImagingCore
import EditModel
import ImageCanvas

enum GlowChecks {
    static func run(_ c: Checks) {
        let pipeline = RenderPipeline()
        func render(_ image: CIImage, amount: Double, radius: Double = 60, ratio: Double = 1) -> CIImage {
            var stack = EditStack()
            stack.custom.glowAmount = amount
            stack.custom.glowRadius = radius
            return pipeline.render(RenderChecks.input(image), stack: stack, proxyRatio: ratio)
        }

        c.suite("Glow model and pipeline order") { c in
            let old = try JSONDecoder().decode(EditStack.self, from: Data(#"{"light":{"exposure":1}}"#.utf8))
            c.expect(old.custom == .neutral, "old sidecar without custom decodes neutral glow")
            let sparse = try JSONDecoder().decode(EditStack.self, from: Data(#"{"custom":{"glowAmount":30}}"#.utf8))
            c.expect(sparse.custom.glowAmount == 30 && sparse.custom.glowRadius == 60,
                     "partial custom retains opacity and defaults radius to 60")
            let radiusOnly = try JSONDecoder().decode(CustomAdjustments.self, from: Data(#"{"glowRadius":40}"#.utf8))
            c.expect(radiusOnly.glowAmount == 0, "missing opacity defaults to zero")
            c.expect(!sparse.isNeutral, "glow marks the stack edited")
            let roundTrip = try JSONDecoder().decode(EditStack.self, from: JSONEncoder().encode(sparse))
            c.expect(roundTrip == sparse,
                     "custom survives a sidecar round trip")
            let stages = RenderPipeline.stages
            if let index = stages.firstIndex(of: .glow), index > 0, index + 1 < stages.count {
                c.expect(stages[index - 1] == .grainAndVignette && stages[index + 1] == .geometry,
                         "glow is immediately after grain/vignette and before geometry")
            } else { c.fail("glow stage is missing or misplaced") }
        }

        c.suite("Glow identity and finite extent") { c in
            let base = RenderChecks.solid(0.5, size: 128)
                .transformed(by: .init(translationX: 13, y: 27))
            let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])
            func pixels(_ image: CIImage) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
                context.render(image, toBitmap: &bytes, rowBytes: 128 * 4, bounds: base.extent,
                               format: .RGBA8, colorSpace: WorkingColorSpace.sRGB)
                return bytes
            }
            let original = pixels(base)
            // A readback sanity check prevents an unavailable renderer making identity vacuous.
            c.expect(original.contains { $0 > 0 }, "glow identity fixture has nonzero readback")
            c.expect(pixels(render(base, amount: 0)) == original, "zero glow is pixel-exact identity across the frame")
            c.expect(pixels(render(base, amount: -1)) == original, "negative glow bypasses the effect")
            for ratio in [1.0, 0.25] {
                let out = render(base, amount: 100, ratio: ratio)
                c.expect(out.extent == base.extent && !out.extent.isInfinite && !out.extent.isNull,
                         "glow preserves finite translated extent at proxyRatio \(ratio)")
            }
            let infinite = CIImage(color: .white)
            c.expect(render(infinite, amount: 100).extent == infinite.extent,
                     "infinite input bypasses glow")
        }

        c.suite("Glow encoded sRGB math") { c in
            let base = RenderChecks.solid(0.5, size: 256)
            for (amount, expected) in [(100.0, 0.75), (30.0, 0.575)] {
                let out = RenderChecks.sample(render(base, amount: amount), at: CGPoint(x: 128, y: 128))
                c.expect([out.r, out.g, out.b].allSatisfy { abs($0 / 255 - expected) <= 1.0 / 255 },
                         "glow \(amount)%: encoded center RGB \(out), expected \(expected)")
            }
            // Unequal channels catch applying the transfer curve to Rec. 2020 primaries.
            let color = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.7,
                                               colorSpace: WorkingColorSpace.sRGB)!)
                .cropped(to: base.extent)
            let out = RenderChecks.sample(render(color, amount: 100), at: CGPoint(x: 128, y: 128))
            c.expect(zip([out.r, out.g, out.b], [0.36, 0.75, 0.91]).allSatisfy { abs($0 / 255 - $1) <= 1.0 / 255 },
                     "glow screens sRGB primaries independently: \(out)")
        }

        c.suite("Glow extended range and small-amount continuity") { c in
            let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])
            let extendedSRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!
            func sample(_ image: CIImage) -> [Float] {
                var values = [Float](repeating: 0, count: 4)
                context.render(image, toBitmap: &values, rowBytes: 4 * MemoryLayout<Float>.size,
                               bounds: CGRect(x: 128, y: 128, width: 1, height: 1),
                               format: .RGBAf, colorSpace: extendedSRGB)
                return values
            }
            let highlight = CIImage(color: CIColor(red: 2, green: 2, blue: 2,
                                                   colorSpace: WorkingColorSpace.linearWide)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
            let bright = sample(render(highlight, amount: 1))
            c.expect(bright.prefix(3).allSatisfy { $0.isFinite && $0 > 1 },
                     "1% glow preserves above-one encoded highlights: \(bright)")

            let grey = RenderChecks.solid(0.5, size: 256)
            let zero = sample(render(grey, amount: 0))
            let one = sample(render(grey, amount: 1))
            c.expect(zero.prefix(3).allSatisfy { abs($0 - 0.5) <= 1.0 / 255 },
                     "continuity fixture reads back encoded mid-grey: \(zero)")
            c.expect(zip(zero.prefix(3), one.prefix(3)).allSatisfy {
                $0.isFinite && $1.isFinite && abs($1 - $0) <= 1.0 / 255
            }, "0% to 1% glow changes mid-grey by at most 1/255 encoded: \(zero) → \(one)")
        }

        c.suite("Glow spatial spread and proxy consistency") { c in
            func fixture(_ scale: CGFloat) -> CIImage {
                let black = RenderChecks.solid(0, size: 320 * scale)
                let white = CIImage(color: .white)
                    .cropped(to: CGRect(x: 128 * scale, y: 128 * scale, width: 64 * scale, height: 64 * scale))
                return white.composited(over: black).cropped(to: black.extent)
            }
            let point = CGPoint(x: 232, y: 160) // 40 full-resolution pixels outside the square.
            let full = RenderChecks.sample(render(fixture(1), amount: 100, radius: 40), at: point).r
            let narrow = RenderChecks.sample(render(fixture(1), amount: 100, radius: 1), at: point).r
            c.expect(full > 3, "radius 40 spreads light 40px past the square (\(full)/255)")
            c.expect(narrow <= 1, "radius 1 stays black 40px past the square (\(narrow)/255)")
            let proxy = RenderChecks.sample(render(fixture(0.5), amount: 100, radius: 40, ratio: 0.5),
                                            at: CGPoint(x: point.x / 2, y: point.y / 2)).r
            c.expect(abs(full - proxy) <= 3, "glow proxy and full agree within 3/255 (\(full), \(proxy))")
            // Ensure the tolerance can detect a missing radius scale, not just two black pixels.
            let unscaled = RenderChecks.sample(render(fixture(0.5), amount: 100, radius: 40),
                                               at: CGPoint(x: point.x / 2, y: point.y / 2)).r
            c.expect(abs(full - unscaled) > 3, "glow proxy fixture detects an unscaled radius")
        }
    }
}
