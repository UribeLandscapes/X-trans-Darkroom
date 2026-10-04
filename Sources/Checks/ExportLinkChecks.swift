import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Export
import EditModel
import ImagingCore

/// Export onto volumes without hard links (exFAT): the exclusive publish must fall back
/// to a create-exclusive copy that still never overwrites an existing file.
enum ExportLinkChecks {
    @MainActor
    static func run(_ c: Checks) async {
        await c.suite("Export: publishes without hard-link support (exFAT)") { c in
            let root = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let out = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("name.tif")
            try writeSource(source)
            var request = ExportRequest(items: [ExportItem(source: source, stack: EditStack())], destination: out)
            request.options.filename = .original

            for code in [ENOTSUP, EPERM, EXDEV] {
                let engine = ExportEngine(link: { _, _ in errno = code; return -1 })
                let dest = out.appendingPathComponent("name.jpg")
                try? FileManager.default.removeItem(at: dest)
                request.options.collision = .addIndex
                let result = await engine.run(request)
                c.expect(result.first?.output == dest && result.first?.error == nil,
                         "errno \(code): export succeeds to a free name (output=\(result.first?.output?.lastPathComponent ?? "nil"), error=\(result.first?.error ?? "none"))")
                c.expect(CGImageSourceCreateWithURL(dest as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil,
                         "errno \(code): published file is a complete image")
                c.expect(leftovers(out) == [], "errno \(code): temporary file removed (\(leftovers(out)))")
            }

            let engine = ExportEngine(link: { _, _ in errno = ENOTSUP; return -1 })
            let existing = out.appendingPathComponent("name.jpg")
            let sentinel = Data("keep me".utf8)
            try sentinel.write(to: existing)

            request.options.collision = .addIndex
            let indexed = await engine.run(request)
            c.expect(indexed.first?.output?.lastPathComponent == "name_1.jpg", "add-index still picks the next free name (got \(indexed.first?.output?.lastPathComponent ?? "nil"))")
            let second = await engine.run(request)
            c.expect(second.first?.output?.lastPathComponent == "name_2.jpg", "add-index keeps incrementing (got \(second.first?.output?.lastPathComponent ?? "nil"))")
            c.expect(try Data(contentsOf: existing) == sentinel, "add-index never overwrites the existing file")

            request.options.collision = .skip
            let skipped = await engine.run(request)
            c.expect(skipped.first?.output == nil && skipped.first?.error == nil, "skip skips an existing file")
            c.expect(try Data(contentsOf: existing) == sentinel, "skip never overwrites the existing file")
            c.expect(leftovers(out) == [], "no temporary files remain after collisions (\(leftovers(out)))")
        }

        await c.suite("Export: failed exFAT copy never deletes anything and reports the partial file") { c in
            struct Injected: Error {}
            let root = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let out = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("name.tif")
            try writeSource(source)
            var request = ExportRequest(items: [ExportItem(source: source, stack: EditStack())], destination: out)
            request.options.filename = .original
            request.options.collision = .addIndex
            let dest = out.appendingPathComponent("name.jpg")
            let noLink: ExportEngine.LinkOperation = { _, _ in errno = ENOTSUP; return -1 }

            let own = ExportEngine(link: noLink, afterCopy: { _ in throw Injected() })
            let failed = await own.run(request)
            c.expect(failed.first?.error != nil, "injected copy failure is reported")
            c.expect(FileManager.default.fileExists(atPath: dest.path), "our own partial file is left in place on failure")
            c.expect(failed.first?.error?.contains(dest.path) == true, "message names the partial file (got \(failed.first?.error ?? "none"))")
            c.expect(failed.first?.error?.contains("Delete it before exporting again") == true, "message tells the user what to do")
            try? FileManager.default.removeItem(at: dest)

            let theirs = Data("someone else".utf8)
            let racing = ExportEngine(link: noLink, afterCopy: { path in
                try FileManager.default.removeItem(atPath: path)
                try theirs.write(to: URL(fileURLWithPath: path))
                throw Injected()
            })
            let raced = await racing.run(request)
            c.expect(raced.first?.error != nil, "failure is still reported when the destination was replaced")
            c.expect((try? Data(contentsOf: dest)) == theirs, "a replacement file written by another writer survives cleanup")
            c.expect(leftovers(out) == [], "no temporary files remain (\(leftovers(out)))")
        }
    }

    private static func leftovers(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".xtd-export-") }
    }

    private static func writeSource(_ url: URL) throws {
        let bytes = [UInt8](repeating: 128, count: 32 * 24 * 4)
        let image = CGImage(width: 32, height: 24, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                            space: WorkingColorSpace.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
    }
}
