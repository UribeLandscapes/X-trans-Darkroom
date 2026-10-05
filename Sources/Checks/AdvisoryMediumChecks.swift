import Foundation
import CoreImage
import ImagingCore
import EditModel
import ImageCanvas
import Profiles
import RecipeUI
import ShortcutLogic

/// Regression checks for the three advisory MEDIUM fixes: colour NR, rotate direction,
/// and the profile-aware thumbnail key.
enum AdvisoryMediumChecks {
    private static let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])

    /// Render the whole image to sRGB RGBA8.
    private static func pixels(_ image: CIImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let r = image.extent
        let w = Int(r.width), h = Int(r.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: r, format: .RGBA8,
                       colorSpace: WorkingColorSpace.sRGB)
        return (bytes, w, h)
    }

    /// Deterministic per-pixel chroma noise (red up, blue down) around mid grey.
    private static func chromaNoise(size: Int) -> CIImage {
        var seed: UInt32 = 12345
        var data = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) {
            seed = seed &* 1664525 &+ 1013904223
            let n = Int(seed >> 24) % 61 - 30
            data[i * 4] = UInt8(128 + n); data[i * 4 + 1] = 128; data[i * 4 + 2] = UInt8(128 - n)
        }
        return CIImage(bitmapData: Data(data), bytesPerRow: size * 4, size: CGSize(width: size, height: size),
                       format: .RGBA8, colorSpace: WorkingColorSpace.sRGB)
    }

    /// Variance of (r - b) over the interior, plus mean luma, so edge effects are ignored.
    private static func chromaStats(_ image: CIImage) -> (variance: Double, luma: Double) {
        let p = pixels(image)
        var chroma: [Double] = [], luma = 0.0
        for y in 8..<(p.height - 8) {
            for x in 8..<(p.width - 8) {
                let i = (y * p.width + x) * 4
                let r = Double(p.bytes[i]), g = Double(p.bytes[i + 1]), b = Double(p.bytes[i + 2])
                chroma.append(r - b); luma += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        let mean = chroma.reduce(0, +) / Double(chroma.count)
        return (chroma.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(chroma.count),
                luma / Double(chroma.count))
    }

    private static func stack(luminanceNR: Double, colorNR: Double) -> EditStack {
        var s = EditStack(); s.detail.luminanceNR = luminanceNR; s.detail.colorNR = colorNR
        return s
    }

    private static func render(_ image: CIImage, _ stack: EditStack) -> CIImage {
        RenderPipeline().render(DecodedFrameInput(image: image, asShotTemperature: 5500), stack: stack, proxyRatio: 1.0)
    }

    /// 64x32 frame, dark, with a white 8x8 marker in the top-left (Core Image y-up: y 24..32).
    private static func markerFrame() -> CIImage {
        let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1, colorSpace: WorkingColorSpace.sRGB)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        let marker = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: WorkingColorSpace.sRGB)!)
            .cropped(to: CGRect(x: 0, y: 24, width: 8, height: 8))
        return marker.composited(over: dark)
    }

    private static func luma(_ image: CIImage, _ x: Int, _ y: Int) -> Double {
        let p = pixels(image)
        let i = ((p.height - 1 - y) * p.width + x) * 4   // bitmap rows run top-down; y is y-up
        return Double(p.bytes[i])
    }

    private static func markerAt(_ image: CIImage, x: Int, y: Int) -> Bool {
        luma(image, x, y) > 200
    }

    static func run(_ c: Checks) {
        colourNoiseChecks(c)
        rotateChecks(c)
        thumbnailKeyChecks(c)
    }

    private static func colourNoiseChecks(_ c: Checks) {
        c.suite("Colour noise reduction smooths chroma, not luminance (advisory M1)") { c in
            let noisy = chromaNoise(size: 64)
            let off = chromaStats(render(noisy, stack(luminanceNR: 0, colorNR: 0)))
            let on = chromaStats(render(noisy, stack(luminanceNR: 0, colorNR: 100)))
            c.expect(on.variance < off.variance * 0.5,
                     String(format: "colorNR 100 halves chroma variance (%.1f -> %.1f)", off.variance, on.variance))
            c.expect(abs(on.luma - off.luma) / off.luma < 0.01,
                     String(format: "colorNR keeps mean luminance within 1%% (%.2f -> %.2f)", off.luma, on.luma))

            let flat = chromaNoise(size: 64)
            let inP = pixels(flat), outP = pixels(render(flat, stack(luminanceNR: 0, colorNR: 0)))
            let worst = zip(inP.bytes, outP.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 255
            c.expect(worst <= 1, "colorNR 0 + luminanceNR 0 leaves pixels untouched (max diff \(worst))")

            let dark = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3, colorSpace: WorkingColorSpace.sRGB)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            let light = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7, colorSpace: WorkingColorSpace.sRGB)!)
                .cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
            let edge = light.composited(over: dark)
            let e0 = render(edge, stack(luminanceNR: 0, colorNR: 0)), e100 = render(edge, stack(luminanceNR: 0, colorNR: 100))
            let c0 = luma(e0, 40, 32) - luma(e0, 24, 32), c100 = luma(e100, 40, 32) - luma(e100, 24, 32)
            c.expect(abs(c100 - c0) <= 2, "colorNR does not change luminance edge contrast (\(c0) vs \(c100))")
            let n0 = luma(e0, 33, 32), n100 = luma(e100, 33, 32)
            c.expect(abs(n100 - n0) <= 2, "colorNR leaves the pixel beside the edge unchanged (\(n0) vs \(n100))")
        }

    }

    private static func rotateChecks(_ c: Checks) {
        c.suite("Rotate left/right directions (advisory M2)") { c in
            var left = EditStack(); left.geometry.rotation = 1
            let l = render(markerFrame(), left)
            c.expect(Int(l.extent.width) == 32 && Int(l.extent.height) == 64, "rotation 1 swaps the frame to 32x64")
            c.expect(markerAt(l, x: 4, y: 4), "rotation 1 turns counter-clockwise: top-left marker lands bottom-left")

            guard case .rotate(let step)? = ShortcutCatalog.entries.first(where: { $0.id == "rotateRight" })?.action else {
                c.fail("rotateRight shortcut has a rotate action"); return
            }
            var right = EditStack(); right.geometry.rotation = (0 + step + 4) % 4
            let r = render(markerFrame(), right)
            c.expect(markerAt(r, x: 28, y: 60), "rotateRight shortcut turns clockwise: top-left marker lands top-right")

            guard case .rotate(let leftStep)? = ShortcutCatalog.entries.first(where: { $0.id == "rotateLeft" })?.action else {
                c.fail("rotateLeft shortcut has a rotate action"); return
            }
            var lq = EditStack(); lq.geometry.rotation = (0 + leftStep + 4) % 4
            c.expect(markerAt(render(markerFrame(), lq), x: 4, y: 4), "rotateLeft shortcut turns counter-clockwise")
        }

    }

    private static func thumbnailKeyChecks(_ c: Checks) {
        c.suite("Thumbnail key tracks profile library (advisory M3)") { c in
            let rafURL = URL(fileURLWithPath: "/nowhere/shot.RAF")
            let jpgURL = URL(fileURLWithPath: "/nowhere/a.jpg")
            let fixture = RecipeChecks.profileFixture()
            // Same-length ASCII edit of the profile name only; offsets and tags stay valid.
            var other = fixture
            guard let nameAt = fixture.range(of: Data("Provia".utf8)) else { c.fail("fixture holds the Provia name"); return }
            other.replaceSubrange(nameAt, with: Data("Velvia".utf8))
            let dirA = try Checks.tempDir(), dirB = try Checks.tempDir(), dirC = try Checks.tempDir(), dirE = try Checks.tempDir()
            defer { for d in [dirA, dirB, dirC, dirE] { try? FileManager.default.removeItem(at: d) } }
            try fixture.write(to: dirA.appendingPathComponent("p.dcp"))
            try fixture.write(to: dirB.appendingPathComponent("renamed.dcp"))
            try other.write(to: dirC.appendingPathComponent("p.dcp"))
            func lib(_ d: URL) -> ProfileLibrary { ProfileLibrary(bundledDirectory: nil, userDirectory: d) }
            let libA = lib(dirA), libC = lib(dirC)
            c.expect(libA.profiles.count == 1 && libC.profiles.count == 1 && libA.profiles[0].identifier != libC.profiles[0].identifier,
                     "both fixture libraries load one valid, distinct profile (\(libA.profiles.count)/\(libC.profiles.count))")
            let a = ThumbnailEditKey.editHash(sidecar: nil, url: rafURL, profiles: lib(dirA))
            let b = ThumbnailEditKey.editHash(sidecar: nil, url: rafURL, profiles: lib(dirB))
            let cc = ThumbnailEditKey.editHash(sidecar: nil, url: rafURL, profiles: lib(dirC))
            let e = ThumbnailEditKey.editHash(sidecar: nil, url: rafURL, profiles: lib(dirE))
            c.expect(a == b, "identical profile content gives an identical key")
            c.expect(a != cc, "a different profile changes the sidecar-less RAF key")
            c.expect(a != e, "removing every profile changes the sidecar-less RAF key")
            let saved = EditStack()
            c.expect(ThumbnailEditKey.editHash(sidecar: saved, url: rafURL, profiles: lib(dirA))
                     == ThumbnailEditKey.editHash(sidecar: saved, url: rafURL, profiles: lib(dirC)),
                     "a sidecar key ignores the profile library")
            c.expect(ThumbnailEditKey.editHash(sidecar: nil, url: jpgURL, profiles: lib(dirA))
                     == ThumbnailEditKey.editHash(sidecar: nil, url: jpgURL, profiles: lib(dirC)),
                     "a non-RAF key ignores the profile library")
        }
    }
}
