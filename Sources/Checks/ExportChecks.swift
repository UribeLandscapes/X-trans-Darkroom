import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Export
import LibraryLogic
import ImagingCore
import ImageCanvas
import EditModel

// These exercise real ImageIO/Core Image output and security bookmarks on hardware.
// They deliberately have no sandbox fallback that could turn missing output into a pass.
enum ExportChecks {
    @MainActor
    static func run(_ c: Checks) async {
        await c.suite("Export settings: construction is lazy and touches no folder") { c in
            let suite = "export-lazy-checks-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            c.expect(defaults.object(forKey: ExportSettings.bookmarkKey) == nil, "fresh defaults have no bookmark")
            let settings = ExportSettings(defaults: defaults)
            c.expect(defaults.object(forKey: ExportSettings.bookmarkKey) == nil, "construction creates no bookmark")
            c.expect((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty, "construction stores nothing")
            let destination = try settings.destination()
            c.expect(sameFolder(destination, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")), "first request resolves Downloads")
            c.expect(defaults.data(forKey: ExportSettings.bookmarkKey)?.isEmpty == false, "first destination request creates the bookmark")
        }
        await c.suite("Export system (Build plan section 8)") { c in
            let root = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let folders = ["A", "B", "C"].map { root.appendingPathComponent($0) }
            for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let suite = "export-checks-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = ExportSettings(defaults: defaults)
            let seeded = try settings.destination()
            c.expect(defaults.data(forKey: ExportSettings.bookmarkKey)?.isEmpty == false, "seed bookmark bytes=\(defaults.data(forKey: ExportSettings.bookmarkKey)?.count ?? 0), expected >0")
            c.expect(sameFolder(seeded, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")), "first destination=\(seeded.path), expected Downloads")
            try settings.setDefault(folders[0])
            let source = root.appendingPathComponent("name.tif")
            try fixture(source)
            let item = ExportItem(source: source, stack: EditStack())
            let engine = ExportEngine()
            var request = try ExportRequest(items: [item], settings: settings)
            let options = request.options
            c.expect(options.format == .jpeg && options.jpegQuality == 90 && options.colorSpace == .sRGB &&
                     options.sharpening == .screen && options.sharpeningAmount == .standard &&
                     options.metadata == .withoutGPS && options.filename == .suffix && options.suffix == "_edit" &&
                     options.collision == .addIndex && options.resize == .none,
                     "defaults: quality=\(options.jpegQuality)/90, space=\(options.colorSpace)/sRGB, sharpening=\(options.sharpening)/Screen, suffix=\(options.suffix)/_edit")
            var naming = options; naming.filename = .pattern; naming.pattern = "{name}-{index}"
            let tokenName = try naming.basename(source: source, index: 7)
            c.expect(tokenName == "name-7", "token filename=\(tokenName)/name-7")
            var fractionalMP = options; fractionalMP.resize = .megapixels; fractionalMP.resizeValue = 0.000768
            let small = fractionalMP.dimensions(width: 64, height: 48)
            c.expect(small.width == 32 && small.height == 24, "fractional MP=0.000768 dimensions=\(small.width)×\(small.height)/32×24")

            for mode in [ResizeMode.shortEdge, .megapixels] {
                var resize = options; resize.resize = mode; resize.resizeValue = 10000
                let dimensions = resize.dimensions(width: 64, height: 48)
                c.expect(dimensions.width == 64 && dimensions.height == 48,
                         "\(mode) no upscale dimensions=\(dimensions.width)×\(dimensions.height)/64×48")
            }

            c.expect(!request.makeDefault, "fresh sheet makeDefault=\(request.makeDefault), expected false")
            request.destination = folders[1]
            try settings.accept(request)
            let first = await engine.run(request)
            let stillA = try settings.destination()
            c.expect(sameFolder(first.first?.output?.deletingLastPathComponent(), folders[1]) && sameFolder(stillA, folders[0]), "override outputs=\(first.compactMap(\.output).map(\.path)), default=\(stillA.lastPathComponent), expected B/A")
            request = try ExportRequest(items: [item], settings: settings)
            let second = await engine.run(request)
            c.expect(sameFolder(second.first?.output?.deletingLastPathComponent(), folders[0]), "next output=\(second.first?.output?.path ?? "nil"), expected A/name_edit.jpg")
            request.destination = folders[2]; request.makeDefault = true
            try settings.accept(request)
            let third = await engine.run(request)
            let defaultC = try settings.destination()
            c.expect(sameFolder(defaultC, folders[2]) && sameFolder(third.first?.output?.deletingLastPathComponent(), folders[2]), "explicit default=\(defaultC.lastPathComponent), outputs=\(third.compactMap(\.output).count)/1 in C")
            let fresh = try ExportRequest(items: [item], settings: settings)
            c.expect(!fresh.makeDefault && sameFolder(fresh.destination, folders[2]), "reopened checkbox=\(fresh.makeDefault), destination=\(fresh.destination.lastPathComponent), expected false/C")
            var discarded = fresh; discarded.destination = folders[1]
            let afterDiscard = try ExportRequest(items: [item], settings: settings)
            c.expect(sameFolder(afterDiscard.destination, folders[2]) && discarded.isOneOff, "discard override=\(discarded.isOneOff), next folder=\(afterDiscard.destination.lastPathComponent)/C")

            for format in ExportFormat.allCases {
                for space in OutputColorSpace.allCases {
                    var r = fresh
                    r.options.format = format; r.options.colorSpace = space
                    r.options.resize = .longEdge; r.options.resizeValue = 32
                    let result = await engine.run(r)
                    guard let url = result.first?.output, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { c.fail("\(format)/\(space) opened=0/1, errors=\(result.compactMap(\.error))"); continue }
                    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
                    let profile = props[kCGImagePropertyProfileName as String] as? String ?? "missing"
                    let expected: String
                    switch space {
                    case .sRGB: expected = "sRGB IEC61966-2.1"
                    case .displayP3: expected = "Display P3"
                    case .adobeRGB: expected = "Adobe RGB (1998)"
                    }
                    c.expect(image.width == 32 && image.height == 24, "\(format)/\(space) opened dimensions=\(image.width)×\(image.height), expected 32×24")
                    c.expect(profile == expected, "\(format)/\(space) embedded profile='\(profile)', expected '\(expected)'")
                }
            }
            for depth in TIFFDepth.allCases {
                for compression in TIFFCompression.allCases {
                    var r = fresh; r.options.format = .tiff; r.options.tiffDepth = depth; r.options.tiffCompression = compression
                    r.options.resize = .longEdge; r.options.resizeValue = 10000
                    let result = await engine.run(r)
                    let url = try output(result)
                    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
                    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
                    let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                    let actualCompression = tiff[kCGImagePropertyTIFFCompression as String] as? Int ?? -1
                    c.expect(image.width == 64 && image.height == 48, "no upscale requested=10000, output=\(image.width)×\(image.height)/64×48")
                    c.expect(image.bitsPerComponent == depth.rawValue && actualCompression == (compression == .lzw ? 5 : 1), "TIFF depth=\(image.bitsPerComponent)/\(depth.rawValue), compression=\(actualCompression)/\(compression == .lzw ? 5 : 1)")
                }
            }
            var collision = fresh; collision.options.filename = .original
            let initialURL = try output(await engine.run(collision))
            let indexedURL = try output(await engine.run(collision))
            c.expect(indexedURL.lastPathComponent == "name_1.jpg", "add-index name=\(indexedURL.lastPathComponent)/name_1.jpg")
            let sentinel = Data("original stays until atomic replacement".utf8)
            try sentinel.write(to: initialURL)
            collision.options.collision = .skip
            let skipped = await engine.run(collision)
            let untouched = try Data(contentsOf: initialURL)
            c.expect(skipped.first?.output == nil && skipped.first?.error == nil && untouched == sentinel, "skip outputs=\(skipped.compactMap(\.output).count)/0, preserved bytes=\(untouched.count)/\(sentinel.count)")
            collision.options.collision = .overwrite
            _ = try output(await engine.run(collision))
            let replaced = try Data(contentsOf: initialURL)
            c.expect(replaced != sentinel && CGImageSourceCreateWithURL(initialURL as CFURL, nil) != nil, "overwrite bytes=\(replaced.count), original=\(sentinel.count), opens=1")

            for policy in MetadataPolicy.allCases {
                var r = fresh; r.options.format = .tiff; r.options.metadata = policy
                let url = try output(await engine.run(r))
                let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
                let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
                let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                let hasEXIF = exif[kCGImagePropertyExifExposureTime as String] != nil
                let copyright = tiff[kCGImagePropertyTIFFCopyright as String] as? String
                c.expect(gps.isEmpty == (policy != .all), "\(policy) GPS fields=\(gps.count), expected \(policy == .all ? ">0" : "0")")
                c.expect(hasEXIF == (policy == .all || policy == .withoutGPS), "\(policy) exposure EXIF=\(hasEXIF), expected \(policy == .all || policy == .withoutGPS)")
                c.expect((copyright != nil) == (policy != .none), "\(policy) copyright=\(copyright ?? "nil"), expected present=\(policy != .none)")
                if policy == .none {
                    // Structural codec tags and the requested ICC remain necessary to
                    // interpret pixels; photographic metadata must be absent.
                    c.expect(exif.isEmpty && gps.isEmpty && tiff[kCGImagePropertyTIFFMake as String] == nil, "none EXIF=\(exif.count)/0 GPS=\(gps.count)/0 camera tags=\(tiff[kCGImagePropertyTIFFMake as String] == nil ? 0 : 1)/0")
                }
            }
            let ci = CIImage(contentsOf: source)!
            let pipeline = RenderPipeline()
            let input = DecodedFrameInput(image: ci, asShotTemperature: 5500)
            let context = CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])
            let previewBefore = pixels(pipeline.render(input, stack: item.stack, proxyRatio: 1), context: context)
            var soft = fresh; soft.options.format = .tiff; soft.options.sharpening = .none
            let softURL = try output(await engine.run(soft))
            soft.options.sharpening = .screen
            let sharpURL = try output(await engine.run(soft))
            let softPixels = pixels(CIImage(contentsOf: softURL)!, context: context)
            let sharpPixels = pixels(CIImage(contentsOf: sharpURL)!, context: context)
            let changed = zip(softPixels, sharpPixels).filter { $0 != $1 }.count
            let previewAfter = pixels(pipeline.render(input, stack: item.stack, proxyRatio: 1), context: context)
            let previewChanges = zip(previewBefore, previewAfter).filter { $0 != $1 }.count
            c.expect(changed > 0, "output sharpening changed components=\(changed)/\(softPixels.count), expected >0")
            c.expect(previewChanges == 0, "same-stack preview changed components=\(previewChanges)/0")

            var batch = try ExportRequest(items: [item, item, item], settings: settings)
            batch.options.suffix = "_cancel"
            let token = ExportCancellation()
            let cancelled = await engine.run(batch, cancellation: token) { progress in
                if progress.index == 1 && progress.fraction == 0.9 { token.cancel() }
            }
            let files = try FileManager.default.contentsOfDirectory(at: folders[2], includingPropertiesForKeys: nil)
            let batchFiles = files.filter { $0.lastPathComponent.contains("_cancel") }
            let partials = files.filter { $0.lastPathComponent.hasPrefix(".xtd-export-") }
            let complete = batchFiles.first.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            c.expect(cancelled.count == 1 && batchFiles.count == 1 && complete != nil, "cancel at file 2: results=\(cancelled.count)/1, intact outputs=\(batchFiles.count)/1")
            c.expect(partials.isEmpty, "cancel partial files=\(partials.count)/0")
            let moved = root.appendingPathComponent("C-renamed")
            try FileManager.default.moveItem(at: folders[2], to: moved)
            let restored = try ExportSettings(defaults: defaults).destination()
            c.expect(sameFolder(restored, moved), "moved bookmark resolves=\(restored.lastPathComponent)/C-renamed")

        }
    }
    private static func sameFolder(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func output(_ results: [ExportResult]) throws -> URL {
        guard let url = results.first?.output else { throw NSError(domain: "ExportChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "No output: \(results.compactMap(\.error))"]) }
        return url
    }
    private static func fixture(_ url: URL) throws {
        var bytes = [UInt8](repeating: 255, count: 64 * 48 * 4)
        for y in 0..<48 { for x in 0..<64 {
            let i = (y * 64 + x) * 4
            let value: UInt8 = (x / 4 + y / 4) % 2 == 0 ? 80 : 180
            bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 64, height: 48, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                            space: WorkingColorSpace.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 8.9, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 79.5, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifISOSpeedRatings: [200]],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCopyright: "Export check", kCGImagePropertyTIFFMake: "Fixture"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
    }
    private static func pixels(_ image: CIImage, context: CIContext) -> [UInt8] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: WorkingColorSpace.sRGB)
        return bytes
    }
}
