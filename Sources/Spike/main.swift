import Foundation
import CoreImage
import ImageIO
import ImagingCore
import EditModel
import RawDecode
import ImageCanvas

/// Build plan Phase 0, Spikes A and B - run against real files.
///
/// A: how fast does the Core Image decoder open a 40 MP X-T5 RAF, at full and draft scale,
///    and does it hand back something neutral?
/// B: does the RAF carry the maker-note lens correction tables the Optics plan (§6) depends on?

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("usage: swift run Spike <file> [file...]")
    exit(2)
}

let decoder = CoreImageRawDecoder()
let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])

func time(_ body: () throws -> Void) rethrows -> Double {
    let t = CFAbsoluteTimeGetCurrent()
    try body()
    return (CFAbsoluteTimeGetCurrent() - t) * 1000
}

/// CIImage is lazy and `createCGImage` defers the actual work, so timing either of them
/// measures nothing. Rendering into a real bitmap buffer forces every pixel to exist.
func realize(_ image: CIImage) {
    let extent = image.extent
    guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return }
    let w = Int(extent.width), h = Int(extent.height)
    var buffer = [UInt8](repeating: 0, count: w * h * 4)
    buffer.withUnsafeMutableBytes { raw in
        context.render(image,
                       toBitmap: raw.baseAddress!,
                       rowBytes: w * 4,
                       bounds: extent,
                       format: .RGBA8,
                       colorSpace: WorkingColorSpace.sRGB)
    }
}

for path in args {
    let url = URL(fileURLWithPath: path)
    print("\n\u{001B}[1m\(url.lastPathComponent)\u{001B}[0m")
    print(String(repeating: "─", count: 60))

    // ── Spike B: what does the file actually carry? ──────────────────────────
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        print("  camera      : \(tiff[kCGImagePropertyTIFFMake] as? String ?? "?") \(tiff[kCGImagePropertyTIFFModel] as? String ?? "?")")
        print("  lens        : \(exif[kCGImagePropertyExifLensModel] as? String ?? "(none reported)")")
        print("  pixels      : \(props[kCGImagePropertyPixelWidth] as? Int ?? 0) × \(props[kCGImagePropertyPixelHeight] as? Int ?? 0)")

        // §6: Fuji writes per-shot distortion / CA / vignetting tables into the maker note.
        // If these are present, discontinued XF lenses need no profile database at all.
        let makerKeys = props.keys.filter { ($0 as String).lowercased().contains("maker") }
        if makerKeys.isEmpty {
            print("  maker note  : \u{001B}[33mnot exposed by ImageIO\u{001B}[0m (needs a direct TIFF/IFD parser - Phase 5)")
        } else {
            for k in makerKeys {
                if let dict = props[k] as? [CFString: Any] {
                    print("  maker note  : \(dict.count) fields exposed")
                    let interesting = dict.keys.map { $0 as String }.filter {
                        let l = $0.lowercased()
                        return l.contains("distort") || l.contains("aberr") || l.contains("vignet")
                            || l.contains("shading") || l.contains("geometric")
                    }
                    print("  correction  : \(interesting.isEmpty ? "no correction fields named by ImageIO" : interesting.joined(separator: ", "))")
                }
            }
        }
    }

    // ── Spike A: decode timing ───────────────────────────────────────────────
    do {
        var full: DecodedFrame?
        let fullMS = try time { full = try decoder.decode(url, scale: .full) }
        guard let full else { continue }

        // Force an actual render, since CIImage construction is lazy - an unrendered
        // decode time is a meaningless number.
        let renderMS = time { realize(full.image) }

        var draft: DecodedFrame?
        let draftMS = try time { draft = try decoder.decode(url, scale: .atLeast(pixels: 512)) }
        let draftRenderMS = time { if let d = draft { realize(d.image) } }

        let mp = full.pixelSize.width * full.pixelSize.height / 1_000_000
        print(String(format: "  decoded     : %.0f × %.0f  (%.1f MP)", full.pixelSize.width, full.pixelSize.height, mp))
        print(String(format: "  full decode : %6.1f ms  + render %6.1f ms  = \u{001B}[1m%.1f ms\u{001B}[0m", fullMS, renderMS, fullMS + renderMS))
        print(String(format: "  draft 512px : %6.1f ms  + render %6.1f ms  = \u{001B}[1m%.1f ms\u{001B}[0m", draftMS, draftRenderMS, draftMS + draftRenderMS))
        print(String(format: "  as-shot WB  : %.0f K, tint %.0f", full.metadata.asShotTemperature, full.metadata.asShotTint))

        // §2 budget check on real data: settle render of the full frame through the pipeline.
        let pipeline = RenderPipeline()
        var stack = EditStack()
        stack.light.exposure = 0.5
        stack.light.contrast = 25
        stack.color.saturation = 20
        let input = DecodedFrameInput(image: full.image, asShotTemperature: full.metadata.asShotTemperature)
        // Warm up once so the measured settle excludes kernel compilation and file cache.
        realize(pipeline.render(input, stack: stack, proxyRatio: 1.0))
        var settleSamples: [Double] = []
        for _ in 0..<3 {
            settleSamples.append(time { realize(pipeline.render(input, stack: stack, proxyRatio: 1.0)) })
        }
        let settleMS = settleSamples.sorted()[settleSamples.count / 2]
        let verdict = settleMS <= RenderCoordinator.settleBudgetMS ? "\u{001B}[32mOK\u{001B}[0m" : "\u{001B}[31mOVER\u{001B}[0m"
        print(String(format: "  settle @full: \u{001B}[1m%.1f ms\u{001B}[0m  (budget %.0f ms) %@", settleMS, RenderCoordinator.settleBudgetMS, verdict))

        // Interactive proxy at a 2560px canvas.
        let ratio = min(1.0, 2560.0 / Double(max(full.pixelSize.width, full.pixelSize.height)))
        let proxy = full.image.transformed(by: .init(scaleX: ratio, y: ratio))
        let proxyInput = DecodedFrameInput(image: proxy, asShotTemperature: full.metadata.asShotTemperature)
        // Discard warm-up frames: the first render of a new kernel chain pays for its
        // compilation, and reporting that as p95 would slander a pipeline that is fine.
        for _ in 0..<8 { realize(pipeline.render(proxyInput, stack: stack, proxyRatio: ratio)) }
        var samples: [Double] = []
        for _ in 0..<60 {
            samples.append(time { realize(pipeline.render(proxyInput, stack: stack, proxyRatio: ratio)) })
        }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(0.95 * Double(sorted.count)))]
        let liveVerdict = p95 <= RenderCoordinator.interactiveBudgetMS ? "\u{001B}[32mOK\u{001B}[0m" : "\u{001B}[33mover budget\u{001B}[0m"
        print(String(format: "  live proxy  : p50 \u{001B}[1m%.2f ms\u{001B}[0m  p95 \u{001B}[1m%.2f ms\u{001B}[0m  (budget 8.3 ms) %@  [ratio %.0f%%]",
                     p50, p95, liveVerdict, ratio * 100))
    } catch {
        print("  \u{001B}[31mdecode failed\u{001B}[0m: \(error)")
    }
}
print("")
