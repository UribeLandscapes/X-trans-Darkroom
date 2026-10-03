import Foundation
import CoreImage
import ImagingCore
import EditModel
import ImageCanvas
import RawDecode

/// Phase 1 verification, run headless.
///
/// The pipeline is a pure function, so its arithmetic can be checked without a window:
/// render a synthetic patch through a known edit and assert the resulting pixel values.
/// This is what stops "the slider moves and something changes" from passing for correct.
enum RenderChecks {

    private static let context = CIContext(options: [
        .workingColorSpace: WorkingColorSpace.linearWide
    ])

    /// Render one pixel of the result and return its sRGB 0-255 components.
    static func sample(_ image: CIImage, at point: CGPoint = CGPoint(x: 4, y: 4)) -> (r: Double, g: Double, b: Double) {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image,
                       toBitmap: &bytes,
                       rowBytes: 4,
                       bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: WorkingColorSpace.sRGB)
        return (Double(bytes[0]), Double(bytes[1]), Double(bytes[2]))
    }

    /// Alpha matters for geometry: a straighten that leaves transparent wedges in the
    /// corners is the classic bug, and RGB-only sampling cannot see it.
    static func sampleAlpha(_ image: CIImage, at point: CGPoint) -> Double {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image,
                       toBitmap: &bytes,
                       rowBytes: 4,
                       bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: WorkingColorSpace.sRGB)
        return Double(bytes[3])
    }

    static func solid(_ level: Double, size: CGFloat = 64) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level, colorSpace: WorkingColorSpace.sRGB)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    static func input(_ image: CIImage) -> DecodedFrameInput {
        DecodedFrameInput(image: image, asShotTemperature: 5500)
    }

    static func run(_ c: Checks) {
        let pipeline = RenderPipeline()

        c.suite("Full pipeline finite extents") { c in
            let adjustments: [(String, (inout EditStack) -> Void)] = [
                ("light (including contrast)", {
                    $0.light.exposure = 0.5; $0.light.contrast = 30
                    $0.light.highlights = 20; $0.light.shadows = 15
                    $0.light.whites = 10; $0.light.blacks = -10
                }),
                ("light / contrast negative bias", { $0.light.contrast = 30 }),
                ("light / contrast positive bias", { $0.light.contrast = -30 }),
                ("light / black clamp", { $0.light.blacks = -20 }),
                ("white balance", { $0.color.temperature = 6200; $0.color.tint = 10 }),
                ("colour", { $0.color.saturation = 20; $0.color.vibrance = 15 }),
                ("curves", {
                    $0.curves.composite = ToneCurve(points: [
                        .init(x: 0, y: 0.05), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)
                    ])
                    $0.curves.red = ToneCurve.identity.adding(.init(x: 0.5, y: 0.55))
                }),
                ("hsl", {
                    var band = HSLBand(); band.hue = 10; band.saturation = 20; band.luminance = 10
                    $0.hsl[.red] = band
                }),
                ("grading", { $0.grading.shadowHue = 240; $0.grading.shadowSaturation = 25 }),
                ("effects / texture", { $0.effects.texture = 30 }),
                ("effects / clarity", { $0.effects.clarity = 30 }),
                ("effects / dehaze negative bias", { $0.effects.dehaze = 20 }),
                ("effects / dehaze positive bias", { $0.effects.dehaze = -20 }),
                ("effects / grain", { $0.effects.grainAmount = 20 }),
                ("effects / vignette", { $0.effects.vignetteAmount = -20 }),
                ("effects (including grain and dehaze)", {
                    $0.effects.texture = 20; $0.effects.clarity = 20; $0.effects.dehaze = 20
                    $0.effects.grainAmount = 20; $0.effects.vignetteAmount = -20
                }),
                ("detail / noise reduction", { $0.detail.luminanceNR = 20; $0.detail.colorNR = 20 }),
                ("detail / sharpening", { $0.detail.sharpenAmount = 30; $0.detail.sharpenRadius = 2 }),
                // These edits preserve the frame. Crop, straighten and quarter turns have
                // intentional dimension changes covered by the existing geometry checks.
                ("geometry / flip", { $0.geometry.flipHorizontal = true }),
                ("geometry / scale", { $0.geometry.transformScale = 1.2 }),
                ("geometry / perspective", {
                    $0.geometry.perspectiveVertical = 15; $0.geometry.perspectiveHorizontal = -10
                })
            ]
            func isFinite(_ extent: CGRect) -> Bool {
                !extent.isInfinite && !extent.isNull &&
                    [extent.minX, extent.minY, extent.maxX, extent.maxY,
                     extent.width, extent.height].allSatisfy { $0.isFinite }
            }
            let knots = (0...8).map { Double($0) / 8 }
            let correction = FujiLensCorrection(
                knots: knots, distortion: knots.map { 8 * $0 * $0 },
                chromaticRed: knots.map { 1 + 0.01 * $0 * $0 },
                chromaticBlue: knots.map { 1 - 0.01 * $0 * $0 },
                vignetting: knots.map { 100 - 20 * $0 * $0 })
            for size in [32, 64, 128, 256] {
                let base = solid(0.5, size: CGFloat(size))
                for ratio in [1.0, 0.25] {
                    for (stage, adjust) in adjustments {
                        var stack = EditStack()
                        adjust(&stack)
                        let output = pipeline.render(input(base), stack: stack, proxyRatio: ratio)
                        c.expect(isFinite(output.extent) && output.extent == base.extent,
                                 "\(stage): extent=\(output.extent), expected=\(base.extent), proxyRatio=\(ratio); finite and unchanged")
                    }
                    // Optics defaults to enabled; a non-identity fixture ensures this
                    // exercises the gain and warp paths rather than their no-data return.
                    let opticalInput = DecodedFrameInput(image: base, asShotTemperature: 5500,
                                                         lensCorrection: correction)
                    let opticalOutput = pipeline.render(opticalInput, stack: EditStack(), proxyRatio: ratio)
                    c.expect(isFinite(opticalOutput.extent) && opticalOutput.extent == base.extent,
                             "optics: extent=\(opticalOutput.extent), expected=\(base.extent), proxyRatio=\(ratio); finite and unchanged")
                }

                // Single-pixel sampling can succeed even when an infinite extent breaks
                // the canvas and full-frame readback. Check RGB, since alpha alone can be nonzero.
                var grain = EditStack(); grain.effects.grainAmount = 20
                let output = pipeline.render(input(base), stack: grain, proxyRatio: 1)
                let validExtent = isFinite(output.extent) && output.extent == base.extent
                c.expect(validExtent, "grain full readback: extent=\(output.extent), expected=\(base.extent); finite and unchanged")
                var bytes = [UInt8](repeating: 0, count: size * size * 4)
                // An invalid extent already fails above; do not allocate or read infinite bounds.
                if validExtent {
                    context.render(output, toBitmap: &bytes, rowBytes: size * 4,
                                   bounds: output.extent, format: .RGBA8,
                                   colorSpace: WorkingColorSpace.sRGB)
                }
                let nonBlack = stride(from: 0, to: bytes.count, by: 4).contains {
                    bytes[$0] > 0 || bytes[$0 + 1] > 0 || bytes[$0 + 2] > 0
                }
                c.expect(validExtent && nonBlack,
                         "grain full readback: extent=\(output.extent), non-black RGB=\(nonBlack), size=\(size)")
            }
        }

        c.suite("Render pipeline arithmetic (Build plan §2, Phase 1)") { c in

            // Identity: a neutral stack must not alter a single pixel. If this drifts, every
            // other measurement in the project is measuring the wrong baseline.
            let mid = solid(0.5)
            let untouched = pipeline.render(input(mid), stack: EditStack(), proxyRatio: 1.0)
            let a = sample(mid), b = sample(untouched)
            c.expect(abs(a.r - b.r) < 1.0 && abs(a.g - b.g) < 1.0 && abs(a.b - b.b) < 1.0,
                     "a neutral edit stack is a true identity (in \(Int(a.r)) → out \(Int(b.r)))")

            // Exposure is defined in stops: +1 EV doubles scene-linear radiance. That is
            // NOT the same as doubling an sRGB-encoded value, so the expectation has to be
            // computed through the transfer function rather than eyeballed.
            func srgbToLinear(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            func linearToSRGB(_ v: Double) -> Double {
                v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
            }
            func expectedAfterEV(_ encoded: Double, _ ev: Double) -> Double {
                linearToSRGB(min(1, srgbToLinear(encoded) * pow(2, ev))) * 255
            }

            var plusOne = EditStack(); plusOne.light.exposure = 1
            let brightened = sample(pipeline.render(input(solid(0.25)), stack: plusOne, proxyRatio: 1.0))
            let wantBright = expectedAfterEV(0.25, 1)
            c.expect(abs(brightened.r - wantBright) <= 3,
                     "+1 EV doubles linear radiance (got \(Int(brightened.r)), want \(Int(wantBright)))")

            var minusOne = EditStack(); minusOne.light.exposure = -1
            let darkened = sample(pipeline.render(input(solid(0.5)), stack: minusOne, proxyRatio: 1.0))
            let wantDark = expectedAfterEV(0.5, -1)
            c.expect(abs(darkened.r - wantDark) <= 3,
                     "-1 EV halves linear radiance (got \(Int(darkened.r)), want \(Int(wantDark)))")

            // Saturation must not move a neutral grey - a desaturating or tinting bug here
            // would be invisible on a photo and fatal to colour accuracy.
            var sat = EditStack(); sat.color.saturation = 100
            let greyAfterSat = sample(pipeline.render(input(solid(0.5)), stack: sat, proxyRatio: 1.0))
            c.expect(abs(greyAfterSat.r - greyAfterSat.g) <= 1 && abs(greyAfterSat.g - greyAfterSat.b) <= 1,
                     "saturation leaves neutral grey neutral (\(Int(greyAfterSat.r)),\(Int(greyAfterSat.g)),\(Int(greyAfterSat.b)))")

            var vib = EditStack(); vib.color.vibrance = 100
            let greyAfterVib = sample(pipeline.render(input(solid(0.5)), stack: vib, proxyRatio: 1.0))
            c.expect(abs(greyAfterVib.r - greyAfterVib.g) <= 1 && abs(greyAfterVib.g - greyAfterVib.b) <= 1,
                     "vibrance leaves neutral grey neutral")

            // Contrast pivots around mid grey: mid stays put, dark goes darker.
            // Contrast pivots on an 18% grey card in linear light. A patch sitting at that
            // pivot must barely move; darker patches go darker, brighter go brighter.
            var contrast = EditStack(); contrast.light.contrast = 50
            let pivotEncoded = linearToSRGB(0.18)
            let pivotBefore = sample(solid(pivotEncoded))
            let pivotAfter = sample(pipeline.render(input(solid(pivotEncoded)), stack: contrast, proxyRatio: 1.0))
            c.expect(abs(pivotAfter.r - pivotBefore.r) <= 3,
                     "contrast holds the 18% grey pivot (\(Int(pivotBefore.r)) → \(Int(pivotAfter.r)))")

            let darkBefore = sample(solid(0.25))
            let darkAfter = sample(pipeline.render(input(solid(0.25)), stack: contrast, proxyRatio: 1.0))
            c.expect(darkAfter.r < darkBefore.r, "positive contrast darkens the shadows")

            let brightBefore = sample(solid(0.75))
            let brightAfter = sample(pipeline.render(input(solid(0.75)), stack: contrast, proxyRatio: 1.0))
            c.expect(brightAfter.r > brightBefore.r, "positive contrast brightens the highlights")

            // Monotonicity: raising a slider must never darken the image.
            var lo = EditStack(); lo.light.exposure = 0.5
            var hi = EditStack(); hi.light.exposure = 1.5
            let loOut = sample(pipeline.render(input(solid(0.2)), stack: lo, proxyRatio: 1.0))
            let hiOut = sample(pipeline.render(input(solid(0.2)), stack: hi, proxyRatio: 1.0))
            c.expect(hiOut.r > loOut.r, "exposure is monotonic (0.5 EV → \(Int(loOut.r)), 1.5 EV → \(Int(hiOut.r)))")
        }

        // Build plan §2: the proxy must not lie. Identical stacks rendered at proxy and full
        // scale have to agree, or every judgement made during a drag is made on a fiction.
        c.suite("Proxy fidelity (Build plan §2, dual-resolution)") { c in
            var stack = EditStack()
            stack.light.exposure = 0.8
            stack.light.contrast = 30
            stack.color.saturation = 25

            let full = solid(0.4, size: 256)
            let proxy = full.transformed(by: .init(scaleX: 0.25, y: 0.25))

            let fullOut = sample(pipeline.render(input(full), stack: stack, proxyRatio: 1.0),
                                 at: CGPoint(x: 128, y: 128))
            let proxyOut = sample(pipeline.render(input(proxy), stack: stack, proxyRatio: 0.25),
                                  at: CGPoint(x: 32, y: 32))

            let dr = abs(fullOut.r - proxyOut.r), dg = abs(fullOut.g - proxyOut.g), db = abs(fullOut.b - proxyOut.b)
            c.expect(dr <= 2 && dg <= 2 && db <= 2,
                     "proxy and full render agree within 2/255 (Δ \(Int(dr)),\(Int(dg)),\(Int(db)))")
        }

        // Phase 3 verification: the histogram has to track the actual image, and its
        // clipping indicators have to fire on genuinely clipped content.
        c.suite("Histogram (Build plan §3, Phase 3)") { c in
            let computer = HistogramComputer()

            guard let dark = computer.compute(solid(0.02, size: 128)),
                  let bright = computer.compute(solid(1.0, size: 128)),
                  let mid = computer.compute(solid(0.5, size: 128)) else {
                c.fail("histogram computation returned nil for a valid image"); return
            }

            func peakBin(_ bins: [Float]) -> Int {
                var best = 0
                for i in bins.indices where bins[i] > bins[best] { best = i }
                return best
            }

            let darkPeak = peakBin(dark.luma)
            let midPeak = peakBin(mid.luma)
            let brightPeak = peakBin(bright.luma)
            c.expect(darkPeak < midPeak && midPeak < brightPeak,
                     "peak bin tracks image brightness (\(darkPeak) < \(midPeak) < \(brightPeak))")
            c.expect(midPeak > 100 && midPeak < 160,
                     "a mid-grey patch peaks near the middle bin (bin \(midPeak))")

            c.expect(bright.highlightClipping > 0.5,
                     "a pure white frame reports highlight clipping (\(String(format: "%.2f", bright.highlightClipping)))")
            c.expect(mid.highlightClipping < 0.005 && mid.shadowClipping < 0.005,
                     "a mid-grey frame reports no clipping at either end")

            c.expect(dark.luma.count == Histogram.binCount, "histogram has 256 bins")

            // The histogram runs alongside the proxy render, so it has to be cheap enough
            // not to eat the interactive budget it is displayed next to.
            let sample = solid(0.45, size: 2048)
            _ = computer.compute(sample)
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10 { _ = computer.compute(sample) }
            let perCall = (CFAbsoluteTimeGetCurrent() - start) / 10 * 1000
            c.expect(perCall < 8.3,
                     String(format: "histogram of a 4 MP proxy costs %.2f ms (must stay under the 8.3 ms frame)", perCall))
        }

        // Phase 3 verification, exactly as the build plan specifies it: apply a known curve
        // and confirm the sampled output lands on the expected value - the curve maths is
        // correct, not merely plausible.
        c.suite("Tone curve (Build plan §3, Phase 3)") { c in
            let identity = ToneCurve.identity
            c.expect(abs(identity.value(at: 0.5) - 0.5) < 1e-9, "identity curve maps 0.5 to 0.5")
            c.expect(abs(identity.value(at: 0.0) - 0.0) < 1e-9, "identity curve maps 0 to 0")
            c.expect(abs(identity.value(at: 1.0) - 1.0) < 1e-9, "identity curve maps 1 to 1")

            // The plan's worked example: input 128 -> output 180.
            let lifted = identity.adding(.init(x: 128.0 / 255.0, y: 180.0 / 255.0))
            let got = lifted.value(at: 128.0 / 255.0) * 255
            c.expect(abs(got - 180) < 1.0,
                     String(format: "a point at 128 maps to 180 (got %.1f)", got))

            // Monotone interpolation must not overshoot: with a control point below the
            // line, nothing between the knots may rise above the neighbouring values.
            let dip = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.2), .init(x: 1, y: 1)])
            var monotonic = true
            var previous = -1.0
            for i in 0...200 {
                let v = dip.value(at: Double(i) / 200)
                if v < previous - 1e-9 { monotonic = false }
                previous = v
            }
            c.expect(monotonic, "monotone cubic never reverses between control points")

            let overshoot = (0...200).map { dip.value(at: Double($0) / 200) }.max() ?? 0
            c.expect(overshoot <= 1.0 + 1e-9, "curve output stays within 0...1")

            let lut = lifted.lut()
            c.expect(lut.count == 256, "LUT has 256 entries")
            c.expect(lut.first! <= lut.last!, "LUT is ordered from the curve's start to its end")

            // Endpoints must survive editing, or the curve stops spanning the range.
            let trimmed = lifted.removing(at: 0)
            c.expect(trimmed.points.count == lifted.points.count, "the first endpoint cannot be removed")
            let mid = lifted.points.firstIndex { abs($0.x - 128.0/255.0) < 0.01 } ?? 1
            c.expect(lifted.removing(at: mid).points.count == lifted.points.count - 1,
                     "an interior point can be removed")

            // End to end through the renderer: a lifting curve must actually brighten pixels.
            let pipeline = RenderPipeline()
            var stack = EditStack()
            stack.curves.composite = lifted
            let before = sample(solid(0.5))
            let after = sample(pipeline.render(input(solid(0.5)), stack: stack, proxyRatio: 1.0))
            // The curve maps 128 -> 180 in display-referred space, and the sample is read
            // back in sRGB, so the rendered result must land on 180 - not merely "brighter".
            // Anything else means the linear<->sRGB round trip around the curve is lossy.
            c.expect(abs(after.r - 180) <= 2,
                     "a curve point at 128->180 renders as 180 (in \(Int(before.r)), out \(Int(after.r)))")
            c.expect(abs(after.r - after.g) <= 2 && abs(after.g - after.b) <= 2,
                     "a composite curve keeps neutral grey neutral")

            var neutralStack = EditStack()
            neutralStack.curves = .neutral
            let untouched = sample(pipeline.render(input(solid(0.5)), stack: neutralStack, proxyRatio: 1.0))
            c.expect(abs(untouched.r - before.r) <= 1, "a neutral curve set is a true identity")
        }

        // A hard vertical edge: the only way to see what a sharpening or local-contrast
        // operation actually did. Left half dark, right half light.
        func stepEdge(size: CGFloat) -> CIImage {
            let dark = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
                .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
            let light = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7))
                .cropped(to: CGRect(x: size / 2, y: 0, width: size / 2, height: size))
            return light.composited(over: dark)
        }

        c.suite("Effects and Detail (Build plan §4, Phase 4)") { c in
            let pipeline = RenderPipeline()
            let base = solid(0.5, size: 128)

            // Neutral must stay neutral now that six more stages exist in the pipeline.
            let neutral = sample(pipeline.render(input(base), stack: EditStack(), proxyRatio: 1.0))
            let raw = sample(base)
            c.expect(abs(neutral.r - raw.r) <= 1,
                     "the full pipeline is still an identity at neutral (\(Int(raw.r)) → \(Int(neutral.r)))")

            // Clarity raises local contrast at an edge: the light side gets lighter.
            var clarity = EditStack(); clarity.effects.clarity = 100
            let edge = stepEdge(size: 128)
            let plainLight = sample(edge, at: CGPoint(x: 70, y: 64))
            let clarityLight = sample(pipeline.render(input(edge), stack: clarity, proxyRatio: 1.0),
                                      at: CGPoint(x: 70, y: 64))
            c.expect(clarityLight.r > plainLight.r,
                     "clarity lifts the light side of an edge (\(Int(plainLight.r)) → \(Int(clarityLight.r)))")

            // Lightroom's convention: negative vignette darkens the corners, positive
            // brightens them. Both directions are checked so the sign cannot silently flip.
            var darkVig = EditStack(); darkVig.effects.vignetteAmount = -100
            let darkened = pipeline.render(input(solid(0.7, size: 256)), stack: darkVig, proxyRatio: 1.0)
            let darkCorner = sample(darkened, at: CGPoint(x: 4, y: 4))
            let darkCentre = sample(darkened, at: CGPoint(x: 128, y: 128))
            c.expect(darkCorner.r < darkCentre.r - 10,
                     "negative vignette darkens the corner (\(Int(darkCorner.r)) vs centre \(Int(darkCentre.r)))")

            var lightVig = EditStack(); lightVig.effects.vignetteAmount = 100
            let brightened = pipeline.render(input(solid(0.4, size: 256)), stack: lightVig, proxyRatio: 1.0)
            let brightCorner = sample(brightened, at: CGPoint(x: 4, y: 4))
            let brightCentre = sample(brightened, at: CGPoint(x: 128, y: 128))
            c.expect(brightCorner.r > brightCentre.r + 5,
                     "positive vignette brightens the corner (\(Int(brightCorner.r)) vs centre \(Int(brightCentre.r)))")

            // Grain must actually vary pixel to pixel, not just shift the whole frame.
            var grain = EditStack(); grain.effects.grainAmount = 100
            let grained = pipeline.render(input(solid(0.5, size: 128)), stack: grain, proxyRatio: 1.0)
            let samples = (0..<24).map { sample(grained, at: CGPoint(x: $0 * 5 + 2, y: 40)).r }
            let mean = samples.reduce(0, +) / Double(samples.count)
            let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)
            c.expect(variance > 1.0,
                     String(format: "grain introduces per-pixel variation (variance %.1f)", variance))

            // Dehaze lifts contrast. Flagged in the pipeline as an approximation, not a
            // physically-based dark-channel dehaze - this check holds it to what it claims.
            var dehaze = EditStack(); dehaze.effects.dehaze = 100
            let hazyDark = sample(pipeline.render(input(solid(0.3, size: 64)), stack: dehaze, proxyRatio: 1.0))
            let hazyLight = sample(pipeline.render(input(solid(0.8, size: 64)), stack: dehaze, proxyRatio: 1.0))
            let plainDark = sample(solid(0.3, size: 64)), plainLight2 = sample(solid(0.8, size: 64))
            c.expect(hazyDark.r < plainDark.r && hazyLight.r > plainLight2.r,
                     "dehaze expands the tonal range in both directions")

            // Sharpening must visibly steepen an edge.
            var sharp = EditStack(); sharp.detail.sharpenAmount = 100; sharp.detail.sharpenRadius = 2
            let sharpened = pipeline.render(input(edge), stack: sharp, proxyRatio: 1.0)
            let sharpLight = sample(sharpened, at: CGPoint(x: 66, y: 64))
            let sharpDark = sample(sharpened, at: CGPoint(x: 61, y: 64))
            let plainDark2 = sample(edge, at: CGPoint(x: 61, y: 64))
            c.expect(sharpLight.r - sharpDark.r > plainLight.r - plainDark2.r,
                     "sharpening steepens the edge transition")
        }

        // The claim §2 rests on: identical parameters must look the same at proxy and full
        // scale. Without the pixel-domain scaling this test fails, which is the whole point.
        c.suite("Scale-aware parameters, end to end (Build plan §2)") { c in
            let pipeline = RenderPipeline()
            var stack = EditStack()
            stack.detail.sharpenAmount = 100
            stack.detail.sharpenRadius = 4
            stack.effects.clarity = 60

            let full = stepEdge(size: 512)
            let proxy = full.transformed(by: .init(scaleX: 0.25, y: 0.25))

            // Sample the same relative position in both renders.
            let fullOut = sample(pipeline.render(input(full), stack: stack, proxyRatio: 1.0),
                                 at: CGPoint(x: 300, y: 256))
            let proxyOut = sample(pipeline.render(input(proxy), stack: stack, proxyRatio: 0.25),
                                  at: CGPoint(x: 75, y: 64))
            let delta = abs(fullOut.r - proxyOut.r)
            c.expect(delta <= 6,
                     "sharpened edge matches between proxy and full render (Δ \(Int(delta))/255)")

            // And the guard that proves the test is meaningful: WITHOUT scaling, the proxy
            // renders a 4px radius on a quarter-size image - a 4x larger effect - and drifts.
            let unscaled = sample(pipeline.render(input(proxy), stack: stack, proxyRatio: 1.0),
                                  at: CGPoint(x: 75, y: 64))
            c.expect(abs(fullOut.r - unscaled.r) > delta,
                     "an unscaled proxy drifts further than the scaled one - the scaling is doing real work")
        }

        c.suite("HSL mixer and colour grading (Build plan §4)") { c in
            let pipeline = RenderPipeline()

            func rgb(_ r: Double, _ g: Double, _ b: Double, size: CGFloat = 64) -> CIImage {
                CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: WorkingColorSpace.sRGB)!)
                    .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
            }

            // HSV round trip must be exact, since both the cube builder and these checks
            // depend on it meaning the same thing.
            for (r, g, b) in [(0.8, 0.2, 0.2), (0.2, 0.7, 0.3), (0.3, 0.4, 0.9), (0.5, 0.5, 0.5)] {
                let hsv = HSV.fromRGB(r, g, b)
                let back = HSV.toRGB(hsv.h, hsv.s, hsv.v)
                c.expect(abs(back.r - r) < 1e-9 && abs(back.g - g) < 1e-9 && abs(back.b - b) < 1e-9,
                         String(format: "HSV round trip is exact for (%.1f, %.1f, %.1f)", r, g, b))
            }
            c.expect(HSV.hueDistance(350, 10) == 20, "hue distance wraps across 0 degrees")

            // Desaturating the red band must drain a red patch and leave a blue one alone.
            var redOnly = EditStack()
            redOnly.hsl[.red] = { var b = HSLBand(); b.saturation = -100; return b }()
            let redBefore = sample(rgb(0.8, 0.15, 0.15))
            let redAfter = sample(pipeline.render(input(rgb(0.8, 0.15, 0.15)), stack: redOnly, proxyRatio: 1.0))
            let redDrop = (redBefore.r - redBefore.g) - (redAfter.r - redAfter.g)
            c.expect(redDrop > 30, "red band desaturation drains a red patch (spread fell by \(Int(redDrop)))")

            let blueBefore = sample(rgb(0.15, 0.2, 0.8))
            let blueAfter = sample(pipeline.render(input(rgb(0.15, 0.2, 0.8)), stack: redOnly, proxyRatio: 1.0))
            c.expect(abs(blueAfter.b - blueBefore.b) <= 6,
                     "the red band leaves a blue patch essentially untouched (\(Int(blueBefore.b)) → \(Int(blueAfter.b)))")

            // Neutral grey has no hue, so no band may move it - the classic HSL bug.
            let greyBefore = sample(solid(0.5))
            let greyAfter = sample(pipeline.render(input(solid(0.5)), stack: redOnly, proxyRatio: 1.0))
            c.expect(abs(greyAfter.r - greyBefore.r) <= 2 && abs(greyAfter.g - greyBefore.g) <= 2,
                     "HSL leaves neutral grey untouched")

            // Colour grading tints shadows without dragging the highlights with it.
            var graded = EditStack()
            graded.grading.shadowHue = 240      // blue
            graded.grading.shadowSaturation = 100
            let shadowOut = sample(pipeline.render(input(solid(0.15)), stack: graded, proxyRatio: 1.0))
            let highlightOut = sample(pipeline.render(input(solid(0.9)), stack: graded, proxyRatio: 1.0))
            let highlightRef = sample(solid(0.9))
            c.expect(shadowOut.b > shadowOut.r + 8,
                     "shadow grading pushes shadows blue (r \(Int(shadowOut.r)) vs b \(Int(shadowOut.b)))")
            c.expect(abs(highlightOut.b - highlightRef.b) <= 6,
                     "shadow grading barely touches the highlights")

            // Neutral must remain a true identity now that a colour cube is in the chain.
            let identityIn = sample(solid(0.45))
            let identityOut = sample(pipeline.render(input(solid(0.45)), stack: EditStack(), proxyRatio: 1.0))
            c.expect(abs(identityIn.r - identityOut.r) <= 1,
                     "a neutral HSL/grading pair adds no cube to the chain")

            // The cube must be cached, or every frame of a drag rebuilds 4913 entries.
            var mix = HSLMix()
            mix[.green] = { var b = HSLBand(); b.luminance = 40; return b }()
            let cache = ColorCubeCache()
            _ = cache.cube(for: mix, grading: .neutral)
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<200 { _ = cache.cube(for: mix, grading: .neutral) }
            let perHit = (CFAbsoluteTimeGetCurrent() - start) / 200 * 1000
            c.expect(perHit < 0.05,
                     String(format: "an unchanged cube is a cache hit (%.4f ms per call)", perHit))

            let buildStart = CFAbsoluteTimeGetCurrent()
            _ = ColorCubeCache.build(mix: mix, grading: .neutral, dimension: 17)
            let buildMS = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000
            c.expect(buildMS < 8.3,
                     String(format: "a cube rebuild fits inside one frame (%.2f ms)", buildMS))
        }

        c.suite("Geometry (Build plan §4, Phase 4c)") { c in
            let pipeline = RenderPipeline()
            let frame = solid(0.5, size: 400)

            // Neutral geometry must not touch the image or its extent.
            let neutral = pipeline.render(input(frame), stack: EditStack(), proxyRatio: 1.0)
            c.expect(neutral.extent.width == 400 && neutral.extent.height == 400,
                     "neutral geometry preserves the extent (\(Int(neutral.extent.width))×\(Int(neutral.extent.height)))")

            // Crop: a half-width, half-height crop yields exactly a quarter of the frame.
            var cropped = EditStack()
            cropped.geometry.cropX = 0.25
            cropped.geometry.cropY = 0.25
            cropped.geometry.cropWidth = 0.5
            cropped.geometry.cropHeight = 0.5
            let cropOut = pipeline.render(input(frame), stack: cropped, proxyRatio: 1.0)
            c.expect(abs(cropOut.extent.width - 200) <= 1 && abs(cropOut.extent.height - 200) <= 1,
                     "a 50% crop halves both dimensions (\(Int(cropOut.extent.width))×\(Int(cropOut.extent.height)))")
            c.expect(cropOut.extent.origin.x == 0 && cropOut.extent.origin.y == 0,
                     "the cropped result is re-originned at 0,0")

            // Straighten: the whole point is that no transparent wedge survives.
            var straight = EditStack()
            straight.geometry.straightenAngle = 8
            let rotated = pipeline.render(input(frame), stack: straight, proxyRatio: 1.0)
            let e = rotated.extent
            c.expect(e.width < 400 && e.width > 200,
                     "straightening trims the frame to fit (\(Int(e.width))×\(Int(e.height)))")

            var opaque = true
            var worst = 255.0
            for (dx, dy) in [(2.0, 2.0), (e.width - 3, 2.0), (2.0, e.height - 3), (e.width - 3, e.height - 3)] {
                let a = sampleAlpha(rotated, at: CGPoint(x: dx, y: dy))
                worst = min(worst, a)
                if a < 250 { opaque = false }
            }
            c.expect(opaque, "no transparent corners after an 8° straighten (worst alpha \(Int(worst))/255)")

            // And a steeper angle must still hold.
            var steep = EditStack(); steep.geometry.straightenAngle = -20
            let steepOut = pipeline.render(input(frame), stack: steep, proxyRatio: 1.0)
            let se = steepOut.extent
            var steepOpaque = true
            for (dx, dy) in [(2.0, 2.0), (se.width - 3, 2.0), (2.0, se.height - 3), (se.width - 3, se.height - 3)] {
                if sampleAlpha(steepOut, at: CGPoint(x: dx, y: dy)) < 250 { steepOpaque = false }
            }
            c.expect(steepOpaque, "no transparent corners after a -20° straighten")

            // The inscribed-rectangle helper: 0° is a no-op, larger angles trim more.
            c.expect(GeometryAdjustments.autoCropScale(angleDegrees: 0, aspect: 1.5) == 1,
                     "auto-crop scale is 1 at zero rotation")
            let s5 = GeometryAdjustments.autoCropScale(angleDegrees: 5, aspect: 1.5)
            let s15 = GeometryAdjustments.autoCropScale(angleDegrees: 15, aspect: 1.5)
            c.expect(s5 > s15 && s15 > 0,
                     String(format: "a steeper angle trims more (5° → %.3f, 15° → %.3f)", s5, s15))
            c.expect(s5 < 1, "any rotation trims something")

            // Quarter turns are lossless and swap the axes on odd turns.
            let wide = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
            var turned = EditStack(); turned.geometry.rotation = 1
            let turnedOut = pipeline.render(input(wide), stack: turned, proxyRatio: 1.0)
            c.expect(abs(turnedOut.extent.width - 200) <= 1 && abs(turnedOut.extent.height - 400) <= 1,
                     "a quarter turn swaps the axes (\(Int(turnedOut.extent.width))×\(Int(turnedOut.extent.height)))")

            // Flips preserve dimensions.
            var flipped = EditStack(); flipped.geometry.flipHorizontal = true
            let flipOut = pipeline.render(input(wide), stack: flipped, proxyRatio: 1.0)
            c.expect(abs(flipOut.extent.width - 400) <= 1 && abs(flipOut.extent.height - 200) <= 1,
                     "a horizontal flip preserves dimensions")

            // Geometry is normalized, so a crop must land on the same relative region at
            // proxy and full scale - otherwise the composition changes when you let go.
            let proxyFrame = frame.transformed(by: .init(scaleX: 0.25, y: 0.25))
            let proxyCrop = pipeline.render(input(proxyFrame), stack: cropped, proxyRatio: 0.25)
            let fullAspect = cropOut.extent.width / cropOut.extent.height
            let proxyAspect = proxyCrop.extent.width / proxyCrop.extent.height
            c.expect(abs(fullAspect - proxyAspect) < 0.02,
                     String(format: "crop aspect matches between proxy and full (%.3f vs %.3f)", fullAspect, proxyAspect))
        }

        // Build plan §6, Phase 5. Runs only when a real RAF is present - these values are
        // ground truth from exiftool on DSCF8122.RAF (XF18-55mm F2.8-4 R LM OIS).
        c.suite("Fuji lens correction parser (Build plan §6, Phase 5)") { c in
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: NSHomeDirectory() + "/Pictures"),
                includingPropertiesForKeys: nil))?
                .flatMap { dir -> [URL] in
                    (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                }
                .filter { $0.pathExtension.uppercased() == "RAF" } ?? []

            guard let raf = candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
                c.expect(true, "no RAF available on this machine - parser check skipped")
                return
            }

            guard let correction = FujiLensCorrection.read(from: raf) else {
                c.fail("could not read correction tables from \(raf.lastPathComponent)")
                return
            }

            c.expect(correction.knots.count == 9, "nine radial knots (\(correction.knots.count))")
            c.expect(correction.distortion.count == 9, "nine distortion values")
            c.expect(correction.vignetting.count == 9, "nine vignetting values")
            c.expect(correction.chromaticRed.count == 9 && correction.chromaticBlue.count == 9,
                     "nine CA scale factors per channel")

            // Ground truth from exiftool.
            c.expect(abs(correction.knots[0] - 0.3535211268) < 1e-6,
                     String(format: "first knot is 0.3535211 (got %.7f)", correction.knots[0]))
            c.expect(abs(correction.knots[8] - 1.06056338) < 1e-6,
                     String(format: "last knot is 1.0605634 (got %.7f)", correction.knots[8]))
            c.expect(abs(correction.vignetting[0] - 95.29980469) < 1e-4,
                     String(format: "centre transmission is 95.2998%% (got %.4f)", correction.vignetting[0]))
            c.expect(abs(correction.vignetting[8] - 62.36279297) < 1e-4,
                     String(format: "corner transmission is 62.3628%% (got %.4f)", correction.vignetting[8]))
            c.expect(abs(correction.distortion[8] - 0.7532958984) < 1e-6,
                     String(format: "outermost distortion is 0.7533%% (got %.7f)", correction.distortion[8]))

            // Knots must increase, or interpolation is meaningless.
            var increasing = true
            for i in 1..<correction.knots.count where correction.knots[i] <= correction.knots[i-1] { increasing = false }
            c.expect(increasing, "knots increase monotonically")

            // The physical claims: a lens is dimmest at the corner, so gain rises outward.
            let centreGain = correction.vignettingGain(atRadius: 0)
            let cornerGain = correction.vignettingGain(atRadius: 1.06)
            c.expect(cornerGain > centreGain,
                     String(format: "vignetting gain rises towards the corner (%.3f → %.3f)", centreGain, cornerGain))
            c.expect(abs(cornerGain - 100.0 / 62.36279297) < 1e-3,
                     String(format: "corner gain cancels the measured falloff (%.4f)", cornerGain))

            // Interpolation must land exactly on a knot value when asked for that radius.
            let atKnot = FujiLensCorrection.sample(correction.vignetting, knots: correction.knots,
                                                   at: correction.knots[3])
            c.expect(abs(atKnot - correction.vignetting[3]) < 1e-9,
                     "sampling exactly at a knot returns that knot's value")

            let table = correction.gainTable()
            c.expect(table.count == 128, "gain table has 128 entries")
            c.expect(table.first! <= table.last!, "gain table increases outward")

            // A JPEG carries no such tables and must not pretend otherwise.
            let jpegs = candidates.isEmpty ? [] : [raf.deletingPathExtension().appendingPathExtension("JPG")]
            for j in jpegs where FileManager.default.fileExists(atPath: j.path) {
                c.expect(FujiLensCorrection.read(from: j) == nil, "a JPEG yields no correction tables")
            }
        }

        c.suite("Lens correction application (Build plan section 6)") { c in
            let filter = LensCorrectionFilter()
            c.expect(filter.kernelsAvailable, "the warp and both colour kernels compile")

            // A small off-centre feature moves clear of its original pixel under this
            // exaggerated radial profile; uniform fields cannot reveal a missing warp.
            let knots = (0...8).map { Double($0) / 8 }
            let synthetic = FujiLensCorrection(
                knots: knots, distortion: knots.map { 8 * $0 * $0 },
                chromaticRed: Array(repeating: 1, count: knots.count),
                chromaticBlue: Array(repeating: 1, count: knots.count),
                vignetting: Array(repeating: 100, count: knots.count))
            let feature = solid(1, size: 256)
                .cropped(to: CGRect(x: 30, y: 30, width: 5, height: 5))
                .composited(over: solid(0, size: 256))
            let originalPoint = CGPoint(x: 32, y: 32)
            let originalBrightness = sample(feature, at: originalPoint).r
            c.expect(originalBrightness > 240, "the synthetic feature starts bright at its known coordinate")
            let warped = filter.apply(feature, correction: synthetic, distortion: true,
                                      vignetting: false, chromaticAberration: false)
            let warpedBrightness = sample(warped, at: originalPoint).r
            c.expect(originalBrightness - warpedBrightness > 100,
                     "distortion moves the feature away from its original pixel (\(originalBrightness) → \(warpedBrightness))")
            let unwarped = filter.apply(feature, correction: synthetic, distortion: false,
                                        vignetting: false, chromaticAberration: false)
            c.expect(sample(unwarped, at: originalPoint).r == originalBrightness,
                     "disabling distortion preserves the same feature pixel")

            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: NSHomeDirectory() + "/Pictures"),
                includingPropertiesForKeys: nil))?
                .flatMap { dir -> [URL] in
                    (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                }
                .filter { $0.pathExtension.uppercased() == "RAF" } ?? []

            guard let raf = candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
                c.expect(true, "no RAF available on this machine - lens application checks skipped (0 RAFs)")
                return
            }
            guard let correction = FujiLensCorrection.read(from: raf) else {
                c.fail("could not read correction tables from \(raf.lastPathComponent)")
                return
            }

            let distortionResidual = correction.fitResidual(correction.distortionPolynomial,
                                                            scales: correction.distortion.map { 1 + $0 / 100 })
            let redResidual = correction.fitResidual(correction.redPolynomial, scales: correction.chromaticRed)
            let blueResidual = correction.fitResidual(correction.bluePolynomial, scales: correction.chromaticBlue)
            c.expect(distortionResidual < 0.002,
                     String(format: "distortion fit residual is below 0.002 (%.8f)", distortionResidual))
            c.expect(redResidual < 0.002,
                     String(format: "red CA fit residual is below 0.002 (%.8f)", redResidual))
            c.expect(blueResidual < 0.002,
                     String(format: "blue CA fit residual is below 0.002 (%.8f)", blueResidual))

            let mid = solid(0.5)
            let corrected = filter.apply(mid, correction: correction, distortion: false,
                                         vignetting: true, chromaticAberration: false)
            let corner = CGPoint(x: 4, y: 4), centre = CGPoint(x: 32, y: 32)
            let cornerGain = sample(corrected, at: corner).r / sample(mid, at: corner).r
            let centreGain = sample(corrected, at: centre).r / sample(mid, at: centre).r
            c.expect(cornerGain > centreGain,
                     String(format: "vignetting correction brightens the corner more than the centre (sRGB gains %.4f > %.4f)",
                            cornerGain, centreGain))

            // A spatially varying patch makes an accidental warp visible even with flat input colours.
            let patch = solid(0.2, size: 16).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 16))
                .composited(over: solid(0.5, size: 16))
            let disabled = filter.apply(patch, correction: correction, distortion: false,
                                        vignetting: false, chromaticAberration: false)
            var empty = correction
            empty.knots = []
            empty.distortion = []
            empty.chromaticRed = []
            empty.chromaticBlue = []
            empty.vignetting = []
            let noTables = filter.apply(patch, correction: empty, distortion: true,
                                        vignetting: true, chromaticAberration: true)
            var disabledDifference = 0.0, emptyDifference = 0.0
            for y in 0..<16 {
                for x in 0..<16 {
                    let point = CGPoint(x: x, y: y)
                    let a = sample(patch, at: point)
                    let b = sample(disabled, at: point), d = sample(noTables, at: point)
                    disabledDifference = max(disabledDifference, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b),
                                             abs(sampleAlpha(patch, at: point) - sampleAlpha(disabled, at: point)))
                    emptyDifference = max(emptyDifference, abs(a.r - d.r), abs(a.g - d.g), abs(a.b - d.b),
                                          abs(sampleAlpha(patch, at: point) - sampleAlpha(noTables, at: point)))
                }
            }
            c.expect(disabledDifference == 0,
                     "all three flags false returns a pixel-identical image (maximum RGBA difference \(disabledDifference) across 256 pixels)")
            c.expect(emptyDifference == 0,
                     "empty correction tables are a no-op (maximum RGBA difference \(emptyDifference) across 256 pixels)")

            var frame = input(mid)
            frame.lensCorrection = correction
            var stack = EditStack()
            stack.optics.correctDistortion = false
            stack.optics.correctVignetting = true
            stack.optics.removeChromaticAberration = false
            let rendered = pipeline.render(frame, stack: stack, proxyRatio: 1.0)
            let pipelineCorner = sample(rendered, at: corner).r
            let filterCorner = sample(corrected, at: corner).r
            c.expect(pipelineCorner == filterCorner,
                     "the pipeline applies the requested vignetting correction (corner \(pipelineCorner), filter \(filterCorner))")
        }

        c.suite("Decoder boundary (Build plan §1)") { c in
            let decoder = CoreImageRawDecoder()
            c.expect(decoder.canDecode(URL(fileURLWithPath: "/x/DSCF0001.RAF")), "RAF is accepted")
            c.expect(decoder.canDecode(URL(fileURLWithPath: "/x/IMG_0001.DNG")), "DNG (S24 Ultra) is accepted")
            c.expect(decoder.canDecode(URL(fileURLWithPath: "/x/DSCF0001.JPG")), "Fuji JPEG is accepted")
            c.expect(!decoder.canDecode(URL(fileURLWithPath: "/x/notes.txt")), "a non-image is rejected")
            c.expect(DecodeScale.atLeast(pixels: 512).isDraft, "thumbnail scale uses the draft decode path")
            c.expect(!DecodeScale.full.isDraft, "full scale never uses draft mode (export fidelity)")
        }
    }
}
