import Foundation
import EditModel
import RawDecode
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Export
import ImageCanvas

/// Regression checks for the data-loss audit (sidecar naming, export overwrite,
/// failed-open persistence, save-error surfacing).
enum DataLossChecks {
    @MainActor
    static func run(_ c: Checks) async {
        sidecarSiblings(c)
        await exportOverwrite(c)
        await failedOpen(c)
        persistence(c)
        switchGuard(c)
    }

    private static func writeImage(_ url: URL, type: UTType, seed: UInt8) throws {
        var bytes = [UInt8](repeating: seed, count: 16 * 16 * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
    }

    @MainActor
    private static func exportOverwrite(_ c: Checks) async {
        await c.suite("Export: overwrite never replaces an original (audit HIGH 2)") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let engine = ExportEngine()
            func request(_ sources: [URL]) -> ExportRequest {
                var r = ExportRequest(items: sources.map { ExportItem(source: $0, stack: EditStack()) }, destination: dir)
                r.options.filename = .original
                r.options.collision = .overwrite
                return r
            }

            // Case 1: another batch input would be overwritten (photo.tif -> photo.jpg).
            let tif = dir.appendingPathComponent("photo.tif")
            let jpg = dir.appendingPathComponent("photo.jpg")
            try writeImage(tif, type: .tiff, seed: 40)
            try writeImage(jpg, type: .jpeg, seed: 200)
            let jpgBefore = try Data(contentsOf: jpg)
            let batch = await engine.run(request([tif, jpg]))
            c.expect(try Data(contentsOf: jpg) == jpgBefore, "batch input photo.jpg is not overwritten by photo.tif's export")
            c.expect(batch.first?.output == nil && batch.first?.error != nil, "the colliding item reports an error instead of an output")

            // Case 2: the destination is an original in the source folder, not in the batch.
            let result = await engine.run(request([tif]))
            c.expect(try Data(contentsOf: jpg) == jpgBefore, "an existing original photo.jpg beside the source survives overwrite export")
            c.expect(result.first?.output == nil && result.first?.error != nil, "refusal is reported as an error")

            // Case 3: non-original destination files are still overwritten (existing behaviour).
            let other = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: other) }
            var r = request([tif]); r.destination = other
            try writeImage(other.appendingPathComponent("photo.jpg"), type: .jpeg, seed: 10)
            let ok = await engine.run(r)
            c.expect(ok.first?.output != nil, "overwrite into a different folder still works")
        }
    }

    private static func write(_ stack: EditStack, to url: URL) throws {
        let encoder = JSONEncoder()
        try encoder.encode(stack).write(to: url)
    }

    private static func sidecarSiblings(_ c: Checks) {
        c.suite("Sidecar: RAW+JPEG siblings (audit HIGH 1)") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let raf = dir.appendingPathComponent("DSCF0001.RAF")
            let jpg = dir.appendingPathComponent("DSCF0001.JPG")
            for url in [raf, jpg] { try Data("x".utf8).write(to: url) }

            c.expect(Sidecar.url(forImageAt: raf) != Sidecar.url(forImageAt: jpg),
                     "RAF and JPG siblings map to distinct sidecar files")
            var a = EditStack(); a.light.exposure = 1
            var b = EditStack(); b.light.exposure = -1
            try Sidecar.save(a, forImageAt: raf)
            try Sidecar.save(b, forImageAt: jpg)
            c.expect(try Sidecar.load(forImageAt: raf)?.light.exposure == 1, "saving the JPG does not overwrite the RAF's edits")
            c.expect(try Sidecar.load(forImageAt: jpg)?.light.exposure == -1, "JPG keeps its own edits")
        }

        c.suite("Sidecar: legacy migration (audit HIGH 1)") { c in
            // Unambiguous: one image owns the stem, so it adopts the legacy sidecar.
            let solo = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: solo) }
            let image = solo.appendingPathComponent("IMG_0001.CR3")
            try Data("x".utf8).write(to: image)
            var legacy = EditStack(); legacy.light.exposure = 0.5
            try write(legacy, to: solo.appendingPathComponent("IMG_0001.xtd.json"))
            c.expect(try Sidecar.load(forImageAt: image)?.light.exposure == 0.5,
                     "a lone image adopts its legacy <stem>.xtd.json")
            c.expect(FileManager.default.fileExists(atPath: solo.appendingPathComponent("IMG_0001.xtd.json").path),
                     "legacy sidecar is left in place")

            // Ambiguous: RAW + JPEG share the legacy file; only the RAW adopts it.
            let pair = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: pair) }
            let raf = pair.appendingPathComponent("DSCF0002.RAF")
            let jpg = pair.appendingPathComponent("DSCF0002.JPG")
            for url in [raf, jpg] { try Data("x".utf8).write(to: url) }
            try write(legacy, to: pair.appendingPathComponent("DSCF0002.xtd.json"))
            c.expect(try Sidecar.load(forImageAt: raf)?.light.exposure == 0.5, "the RAW sibling adopts the shared legacy sidecar")
            c.expect(try Sidecar.load(forImageAt: jpg) == nil, "the JPEG sibling does not receive the RAW's legacy edits")

            // Ambiguous with no single RAW: nobody adopts.
            let two = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: two) }
            let p = two.appendingPathComponent("a.PNG"), j = two.appendingPathComponent("a.JPG")
            for url in [p, j] { try Data("x".utf8).write(to: url) }
            try write(legacy, to: two.appendingPathComponent("a.xtd.json"))
            c.expect(try Sidecar.load(forImageAt: p) == nil && Sidecar.load(forImageAt: j) == nil,
                     "two non-RAW siblings: neither adopts the ambiguous legacy sidecar")

            // Listing failure or a listing that omits the image: ownership is unconfirmed.
            struct ListError: Error {}
            c.expect(!Sidecar.ownsLegacySidecar(raf, listing: { _ in throw ListError() }),
                     "folder listing failure: legacy sidecar is not adopted")
            c.expect(!Sidecar.ownsLegacySidecar(jpg, listing: { _ in throw ListError() }),
                     "folder listing failure: the JPEG does not adopt either")
            c.expect(!Sidecar.ownsLegacySidecar(raf, listing: { _ in [] }),
                     "a listing that does not contain the image confirms no owner")
            c.expect(Sidecar.ownsLegacySidecar(raf, listing: { _ in ["DSCF0002.RAF"] }),
                     "a listing with only the image itself confirms sole ownership")

            // A new-style sidecar always wins over the legacy one.
            var fresh = EditStack(); fresh.light.exposure = 2
            try Sidecar.save(fresh, forImageAt: image)
            c.expect(try Sidecar.load(forImageAt: image)?.light.exposure == 2, "new-style sidecar takes precedence over legacy")
        }
    }

    @MainActor
    private static func failedOpen(_ c: Checks) async {
        await c.suite("Failed open clears the previous source (audit HIGH 3)") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let good = dir.appendingPathComponent("good.jpg")
            try writeImage(good, type: .jpeg, seed: 90)
            let coordinator = RenderCoordinator()
            coordinator.open(good, canvasLongEdge: 512)
            c.expect(coordinator.hasImage && coordinator.sourceURL == good, "a readable photo opens and becomes the source")
            coordinator.open(dir.appendingPathComponent("missing.jpg"), canvasLongEdge: 512)
            c.expect(coordinator.lastError != nil, "failed open reports an error")
            c.expect(!coordinator.hasImage, "failed open leaves no decoded image")
            c.expect(coordinator.sourceURL == nil, "failed open clears sourceURL instead of keeping the previous photo")
        }
    }

    private struct Boom: Error {}

    private static func persistence(_ c: Checks) {
        c.suite("Sidecar persistence guard and save errors (audit HIGH 3, 4)") { c in
            let a = URL(fileURLWithPath: "/tmp/a.RAF"), b = URL(fileURLWithPath: "/tmp/b.RAF")
            var stack = EditStack(); stack.light.exposure = 1
            var written: [URL] = []
            var p = SidecarPersistence()
            p.adopt(stackFor: b)
            c.expect(!p.save(stack, currentSource: a, write: { _, u in written.append(u) }) && written.isEmpty,
                     "stack opened for b is never written over source a's sidecar")
            c.expect(!p.save(stack, currentSource: nil, write: { _, u in written.append(u) }) && written.isEmpty,
                     "no current source means no write")
            c.expect(p.save(stack, currentSource: b, write: { _, u in written.append(u) }) && written == [b],
                     "matching source is written")
            c.expect(!p.isDirty && p.failure == nil, "successful save is clean")

            let failed = p.save(stack, currentSource: b, write: { _, _ in throw Boom() })
            c.expect(!failed, "failed write is reported to the caller")
            c.expect(p.isDirty, "failed write keeps the edits marked dirty")
            c.expect(p.failure != nil, "failed write exposes a message for the user")
            c.expect(p.save(stack, currentSource: b, write: { _, _ in }) && !p.isDirty && p.failure == nil,
                     "retry succeeds, clears dirty and the message")
        }
        }

    private static func switchGuard(_ c: Checks) {
        c.suite("Switching photos keeps unsaved edits (audit HIGH 4)") { c in
            let a = URL(fileURLWithPath: "/tmp/a.RAF")
            let stack = EditStack()
            func failing() -> SidecarPersistence {
                var p = SidecarPersistence()
                p.adopt(stackFor: a)
                p.save(stack, currentSource: a, write: { _, _ in throw Boom() })
                return p
            }

            var clean = SidecarPersistence()
            clean.adopt(stackFor: a)
            c.expect(clean.prepareSwitch(stack, currentSource: a, write: { _, _ in }) == .proceed,
                     "clean state switches freely")

            var blocked = failing()
            let decision = blocked.prepareSwitch(stack, currentSource: a, write: { _, _ in throw Boom() })
            var isBlocked = false
            if case .blocked(let message) = decision { isBlocked = message.contains("a.RAF") }
            c.expect(isBlocked, "switch is blocked when the retry save still fails, naming the photo")
            c.expect(blocked.isDirty && blocked.failure != nil, "blocked switch leaves edits dirty with the message")

            var recovered = failing()
            c.expect(recovered.prepareSwitch(stack, currentSource: a, write: { _, _ in }) == .proceed,
                     "switch proceeds when the retry save succeeds")
            c.expect(!recovered.isDirty && recovered.failure == nil, "successful retry clears dirty")

            var discarded = failing()
            discarded.discardUnsavedEdits()
            c.expect(!discarded.isDirty && discarded.failure == nil, "explicit discard clears dirty and the message")
            c.expect(discarded.prepareSwitch(stack, currentSource: a, write: { _, _ in throw Boom() }) == .proceed,
                     "after discard the switch proceeds")
        }
    }
}
