import Foundation
import Catalog
import EditModel
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@MainActor
private func writeScanImage(_ url: URL) throws {
    let pixels = Data(repeating: 128, count: 1024 * 512 * 4)
    guard let provider = CGDataProvider(data: pixels as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: 1024, height: 512, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 1024 * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CatalogErrorForChecks.fixture }
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Check camera"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8,
                                       kCGImagePropertyExifISOSpeedRatings: [400]]
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CatalogErrorForChecks.fixture }
}

private enum CatalogErrorForChecks: Error { case fixture }

enum CatalogChecks {
    @MainActor
    static func run(_ c: Checks) async {
        await c.suite("Catalog and thumbnail cache (Build plan section 7)") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let databaseURL = dir.appendingPathComponent("catalog.sqlite")
            let catalog = try Catalog(url: databaseURL)
            var raw = ImageRecord(path: dir.appendingPathComponent("quote's/DSCF1234.RAF").path, fingerprint: "raw-fingerprint")
            raw.captureDate = Date(timeIntervalSince1970: 123456)
            raw.cameraModel = "FUJIFILM X-T5"; raw.lensModel = "XF 23mm"
            raw.iso = 400; raw.aperture = 2.8; raw.shutter = 0.008; raw.focalLength = 23
            raw.pixelWidth = 7728; raw.pixelHeight = 5152
            raw.rating = 3; raw.flag = 1; raw.colorLabel = "red's"; raw.editHash = "stack-v1"; raw.isRaw = true
            let rawID = try await catalog.upsert(raw)
            raw.id = rawID
            let roundTrip = try await catalog.fetch(folder: raw.folder)
            c.expect(roundTrip == [raw], "all 20 fields round-trip; rows=\(roundTrip.count), id=\(rawID)")
            let repeatedID = try await catalog.upsert(raw)
            let repeatedCount = try await catalog.count()
            c.expect(repeatedCount == 1 && repeatedID == rawID,
                     "same-path upsert preserves one row and id; count=\(repeatedCount), ids=\(rawID)/\(repeatedID)")

            var jpeg = ImageRecord(path: dir.appendingPathComponent("quote's/DSCF1234.JPG").path, fingerprint: "jpeg-fingerprint")
            jpeg.captureDate = Date(timeIntervalSince1970: 123457)
            jpeg.rating = 1
            let jpegID = try await catalog.upsert(jpeg)
            let pair = try await catalog.fetch(folder: raw.folder)
            c.expect(pair.count == 2 && rawID != jpegID,
                     "same-basename RAF/JPEG are independent; rows=\(pair.count), ids=\(rawID)/\(jpegID)")
            c.expect(pair.first(where: { $0.id == jpegID })?.pixelWidth == nil,
                     "absent metadata remains NULL; nil-width rows=\(pair.filter { $0.pixelWidth == nil }.count)")

            try await catalog.setRating(5, for: rawID)
            try await catalog.setFlag(-1, for: rawID)
            try await catalog.setColorLabel("blue' OR 1=1 --", for: rawID)
            // Opening a separate connection proves commits are visible on disk rather
            // than merely reflected in the actor's in-memory state.
            let reopened = try Catalog(url: databaseURL)
            let persisted = try await reopened.record(path: raw.path)
            c.expect(persisted?.rating == 5 && persisted?.flag == -1 && persisted?.colorLabel == "blue' OR 1=1 --",
                     "reopened annotations persist with bound quotes; rating=\(persisted?.rating ?? -99), flag=\(persisted?.flag ?? -99), label bytes=\(persisted?.colorLabel.utf8.count ?? 0)")
            let byRating = try await reopened.fetch(folder: raw.folder, sortBy: .ratingDescending)
            let byDate = try await reopened.fetch(folder: raw.folder, sortBy: .captureDateDescending)
            let byName = try await reopened.fetch(folder: raw.folder)
            c.expect(byRating.map(\.id) == [rawID, jpegID] && byDate.map(\.id) == [jpegID, rawID] && byName.map(\.id) == [jpegID, rawID],
                     "rating/date/name sorts agree; ratings=\(byRating.map(\.rating)), date ids=\(byDate.compactMap(\.id)), name ids=\(byName.compactMap(\.id))")
            let filtered = try await reopened.fetch(folder: raw.folder, filter: .init(minimumRating: 4, flag: -1, colorLabel: "blue' OR 1=1 --", isRaw: true))
            let rendered = try await reopened.fetch(filter: .init(isRaw: false))
            let missingFolder = try await reopened.fetch(folder: "missing")
            c.expect(filtered.map(\.id) == [rawID] && rendered.map(\.id) == [jpegID] && missingFolder.isEmpty,
                     "combined filters and exact folders select subsets; raw=\(filtered.count), rendered=\(rendered.count), missing=\(missingFolder.count)")
            try await reopened.delete(id: jpegID)
            let remaining = try await catalog.count()
            c.expect(remaining == 1, "delete is visible across connections; remaining=\(remaining)")

            let key = ThumbnailCache.key(fingerprint: raw.fingerprint, editHash: "a", size: .grid)
            let same = ThumbnailCache.key(fingerprint: raw.fingerprint, editHash: "a", size: .grid)
            let edited = ThumbnailCache.key(fingerprint: raw.fingerprint, editHash: "b", size: .grid)
            let previewKey = ThumbnailCache.key(fingerprint: raw.fingerprint, editHash: "a", size: .preview)
            let jpegKey = ThumbnailCache.key(fingerprint: jpeg.fingerprint, editHash: "a", size: .grid)
            c.expect(key == same && key != edited && key != previewKey && key != jpegKey && key.count == 64,
                     "stable SHA256 distinguishes edits, sizes and sources; hex=\(key.count), distinct=\(Set([key, edited, previewKey, jpegKey]).count)")
            let framedA = ThumbnailCache.key(fingerprint: "ab", editHash: "c", size: .grid)
            let framedB = ThumbnailCache.key(fingerprint: "a", editHash: "bc", size: .grid)
            c.expect(framedA != framedB, "length-framed key has no concatenation ambiguity; distinct=\(Set([framedA, framedB]).count)")

            let cacheRoot = dir.appendingPathComponent("derivatives")
            let cache = try ThumbnailCache(root: cacheRoot, byteCeiling: 12)
            let gridOld = cache.fileURL(fingerprint: "grid-old", editHash: "", size: .grid)
            let gridNew = cache.fileURL(fingerprint: "grid-new", editHash: "", size: .grid)
            let preview = cache.fileURL(fingerprint: "preview", editHash: "", size: .preview)
            // Controlled byte fixtures isolate disk eviction from the image encoder.
            for (index, url) in [gridOld, gridNew, preview].enumerated() {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0, count: 6).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: url.path)
            }
            let shardKey = ThumbnailCache.key(fingerprint: "grid-old", editHash: "", size: .grid)
            c.expect(gridOld.deletingLastPathComponent().lastPathComponent == String(shardKey.dropFirst(2).prefix(2)) &&
                     gridOld.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == String(shardKey.prefix(2)),
                     "two-level key sharding uses four hex characters; levels=\(gridOld.pathComponents.count - cacheRoot.pathComponents.count - 1)")
            try await cache.evict()
            let bytes = try await cache.byteCount()
            c.expect(bytes == 12 && !FileManager.default.fileExists(atPath: preview.path) && FileManager.default.fileExists(atPath: gridOld.path),
                     "newer preview evicted before older grids; bytes=\(bytes), ceiling=12")
            let touched = try await cache.cachedURL(fingerprint: "grid-old", editHash: "", size: .grid)
            let tighter = try ThumbnailCache(root: cacheRoot, byteCeiling: 6)
            let tighterBytes = try await tighter.byteCount()
            c.expect(touched == gridOld && tighterBytes == 6 && FileManager.default.fileExists(atPath: gridOld.path) && !FileManager.default.fileExists(atPath: gridNew.path),
                     "persisted LRU survives reopening and evicts untouched grid; bytes=\(tighterBytes), ceiling=6")
            let zero = try ThumbnailCache(root: cacheRoot, byteCeiling: 0)
            let zeroBytes = try await zero.byteCount()
            c.expect(zeroBytes == 0, "zero-byte ceiling empties derivatives; bytes=\(zeroBytes)")

            let scanRoot = dir.appendingPathComponent("scan")
            let nested = scanRoot.appendingPathComponent("nested")
            let hidden = scanRoot.appendingPathComponent(".hidden")
            let package = scanRoot.appendingPathComponent("Sample.app")
            for folder in [nested, hidden, package] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let imageURL = nested.appendingPathComponent("fixture.PNG")
            try writeScanImage(imageURL)
            for name in ["same.RAF", "same.JPG", "unsupported.gif", "notes.txt", ".hidden.jpg", ".hidden/inside.png", "Sample.app/inside.png"] {
                try Data("fixture".utf8).write(to: scanRoot.appendingPathComponent(name))
            }
            let scanCatalog = try Catalog(url: dir.appendingPathComponent("scan.sqlite"))
            let scanner = Scanner(catalog: scanCatalog)
            let scan = scanner.scan(root: scanRoot)
            var progress: [(scanned: Int, total: Int)] = []
            for await value in scan.progress { progress.append(value) }
            let result = try await scan.result.value
            let scannedRows = try await scanCatalog.fetch()
            c.expect(result.scanned == 3 && result.updated == 3 && scannedRows.count == 3,
                     "recursive scanner skips unsupported, hidden and package files; scanned=\(result.scanned), updated=\(result.updated), rows=\(scannedRows.count)")
            c.expect(progress.last?.scanned == 3 && progress.last?.total == 3 && zip(progress, progress.dropFirst()).allSatisfy { $0.scanned <= $1.scanned },
                     "AsyncStream progress is monotonic and completes; events=\(progress.count), final=\(progress.last?.scanned ?? -1)/\(progress.last?.total ?? -1)")
            let scanPair = scannedRows.filter { $0.filename.hasPrefix("same.") }
            c.expect(scanPair.count == 2 && Set(scanPair.compactMap(\.id)).count == 2 && Set(scanPair.map(\.fingerprint)).count == 2,
                     "scanner preserves independent RAF/JPEG sources; rows=\(scanPair.count), unique ids=\(Set(scanPair.compactMap(\.id)).count)")
            let imageRow = try await scanCatalog.record(path: imageURL.path)
            c.expect(imageRow?.pixelWidth == 1024 && imageRow?.pixelHeight == 512 && imageRow?.cameraModel == "Check camera" && imageRow?.iso == 400,
                     "scanner indexes image dimensions and metadata; size=\(imageRow?.pixelWidth ?? 0)x\(imageRow?.pixelHeight ?? 0), ISO=\(imageRow?.iso ?? 0)")
            let rescan = try await scanner.scan(root: scanRoot).result.value
            c.expect(rescan.updated == 0 && rescan.skipped == 3, "unchanged rescan skips metadata work; updated=\(rescan.updated), skipped=\(rescan.skipped)")
            guard let changedID = scanPair.first?.id, let changedPath = scanPair.first?.path else { throw CatalogErrorForChecks.fixture }
            try await scanCatalog.setRating(4, for: changedID)
            try Data("changed fixture with different size".utf8).write(to: URL(fileURLWithPath: changedPath))
            let changedScan = try await scanner.scan(root: scanRoot).result.value
            let changedRow = try await scanCatalog.record(path: changedPath)
            c.expect(changedScan.updated == 1 && changedScan.skipped == 2 && changedRow?.id == changedID && changedRow?.rating == 4,
                     "changed source refresh preserves identity and annotations; updated=\(changedScan.updated), skipped=\(changedScan.skipped), rating=\(changedRow?.rating ?? -1)")

            let generatedCache = try ThumbnailCache(root: dir.appendingPathComponent("generated"), byteCeiling: 10_000_000)
            let fingerprint = try SourceFingerprint.compute(for: imageURL)
            async let first = generatedCache.thumbnail(for: imageURL, fingerprint: fingerprint, size: .grid)
            async let second = generatedCache.thumbnail(for: imageURL, fingerprint: fingerprint, size: .grid)
            let (firstURL, secondURL) = try await (first, second)
            guard let encoded = CGImageSourceCreateWithURL(firstURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any] else {
                throw CatalogErrorForChecks.fixture
            }
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let type = CGImageSourceGetType(encoded) as String?
            c.expect(firstURL == secondURL && type == UTType.heic.identifier && width == 512 && height == 256,
                     "concurrent grid requests share a valid HEIC; size=\(width)x\(height), distinct URLs=\(Set([firstURL, secondURL]).count)")
            let previewURL = try await generatedCache.thumbnail(for: imageURL, fingerprint: fingerprint, size: .preview)
            let editedURL = try await generatedCache.thumbnail(for: imageURL, fingerprint: fingerprint, editHash: "cropped", size: .grid) { frame in
                frame.image.cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
            }
            let editedSource = CGImageSourceCreateWithURL(editedURL as CFURL, nil)!
            let editedProps = CGImageSourceCopyPropertiesAtIndex(editedSource, 0, nil) as? [CFString: Any]
            let editedWidth = editedProps?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let generatedBytes = try await generatedCache.byteCount()
            c.expect(previewURL != firstURL && editedURL != firstURL && editedWidth == 128 && generatedBytes <= 10_000_000,
                     "preview and rendered edit have independent HEICs; edited width=\(editedWidth), cache bytes=\(generatedBytes), ceiling=10000000")
        }
    }
}
