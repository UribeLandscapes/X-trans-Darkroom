import Foundation
import RawDecode
import EditModel
import Catalog
import LibraryLogic
import ShortcutLogic
import SQLite3

@MainActor
enum MultiCameraChecks {
    static func run(_ c: Checks) async {
        c.suite("Multi-camera pure policies") { c in
            let raw = ["raf", "cr2", "cr3", "crw", "dng"]
            let rendered = ["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "png"]
            c.expect(SupportedFormats.raw == Set(raw) && SupportedFormats.rendered == Set(rendered), "complete shared format registry")
            for ext in raw + rendered {
                let url = URL(fileURLWithPath: "/synthetic/IMG_0001.\(ext.uppercased())")
                c.expect(CoreImageRawDecoder().canDecode(url), "case-insensitive support: \(ext)")
                c.expect(EditStack.freshOpenDefault(for: url).detail.colorNR == (raw.contains(ext) ? 25 : 0), "fresh-open NR: \(ext)")
            }
            c.expect(!CoreImageRawDecoder().canDecode(URL(fileURLWithPath: "/synthetic/test.nef")), "unsupported extension rejected")
            let cases: [(String, String, Bool, CameraSource.Brand, Bool)] = [
                ("RAF", "fujifilm", false, .fujifilm, true), ("raf", "", true, .other, true),
                ("raf", "", false, .other, false), ("cr3", "Canon Inc.", false, .canon, false),
                ("DNG", "Apple", false, .apple, false), ("hif", "FUJIFILM", false, .fujifilm, false),
                ("jpg", "FUJIFILM", false, .fujifilm, false), ("dng", "FUJIFILM", false, .fujifilm, false)
            ]
            for (ext, make, magic, brand, eligible) in cases {
                let source = CameraSource(extension: ext, make: make, hasRAFMagic: magic)
                c.expect(source.brand == brand && source.isFujifilmRAF == eligible, "Camera / recipe apply / attribution predicate: \(ext), \(make), magic=\(magic)")
                for supported in [false, true] {
                    for enabled in [false, true] {
                        c.expect(source.usesBuiltInLensCorrection(supported: supported, enabled: enabled) ==
                            (source.isRaw && !eligible && supported && enabled), "Apple correction policy: \(ext) supported=\(supported) enabled=\(enabled)")
                    }
                }
                for filter in [false, true] {
                    for output in [false, true] {
                        c.expect(source.needsEmbeddedPreview(filterAvailable: filter, outputAvailable: output) ==
                            (source.isRaw && (!filter || !output)), "fallback decision: \(ext) filter=\(filter) output=\(output)")
                    }
                }
            }
            c.expect(!ShortcutCatalog.enabledForCamera(section: "Recipes", isFujifilmRAF: false) &&
                     ShortcutCatalog.enabledForCamera(section: "Recipes", isFujifilmRAF: true) &&
                     ShortcutCatalog.enabledForCamera(section: "Develop", isFujifilmRAF: false), "catalog gates recipe shortcuts without disabling general editing")
            var metadata = CaptureMetadata()
            metadata.cameraModel = "Synthetic model"
            c.expect(metadata.fallbackStatus == nil, "normal decode has no fallback status")
            metadata.isEmbeddedPreviewFallback = true
            c.expect(metadata.fallbackStatus == "Synthetic model RAW not supported by macOS - editing embedded JPEG preview", "fallback status names camera")
            let optics = try JSONDecoder().decode(OpticsAdjustments.self, from: Data("{}".utf8))
            c.expect(optics == .neutral && optics.builtInLensCorrection, "old sidecars retain neutral decode defaults")
            var stack = EditStack(); stack.optics.builtInLensCorrection = false
            stack.recipeID = "retained"; stack.cameraSettings = ["film_simulation": "Classic Chrome"]
            let saved = try JSONDecoder().decode(EditStack.self, from: JSONEncoder().encode(stack))
            c.expect(saved == stack, "camera data and disabled built-in correction survive sidecar round trip")
            let rows = [("RAF", "FUJIFILM"), ("CR3", "Canon"), ("DNG", "Apple"), ("HIF", "FUJIFILM"), ("JPG", "FUJIFILM")].map { ext, make in
                var row = ImageRecord(path: "/synthetic/IMG_0001.\(ext)", fingerprint: ext)
                row.cameraMake = make
                return row
            }
            let selection = RecipeSelection(rows)
            c.expect(selection.eligible.map(\.ext) == ["raf"] && selection.skipped == 4, "synthetic library selection skips non-Fuji RAF")
            c.expect(selection.status(applied: 1) == "Applied to 1 of 5 (skipped non-Fujifilm RAF)", "batch apply reports eligible and total counts")
            let app = Checks.repoRoot().appendingPathComponent("Sources/App")
            let inspector = try String(contentsOf: app.appendingPathComponent("InspectorView.swift"), encoding: .utf8)
            let browser = try String(contentsOf: app.appendingPathComponent("RecipeBrowserView.swift"), encoding: .utf8)
            let editor = try String(contentsOf: app.appendingPathComponent("EditorModel.swift"), encoding: .utf8)
            c.expect(inspector.contains("$0 != .camera || editor.canUseCamera") && browser.contains("if editor.canUseCamera && !editor.libraryMode"), "Camera section and attribution consume source eligibility")
            c.expect(browser.contains(".disabled(!editor.canApplyRecipe") && editor.contains("guard canUseCamera else { return }"), "recipe UI and model both gate application")
            let canvas = Checks.repoRoot().appendingPathComponent("Sources/ImageCanvas")
            let files = try FileManager.default.contentsOfDirectory(at: canvas, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            c.expect(try files.allSatisfy { try !String(contentsOf: $0, encoding: .utf8).contains("recipeID") }, "ImageCanvas has zero recipeID references")
        }
        await c.suite("Multi-camera catalog synthetic rows") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let catalog = try Catalog(url: dir.appendingPathComponent("catalog.sqlite"))
            for (name, make) in [("IMG_0001.CR3", "Canon"), ("IMG_0001.JPG", "Canon"), ("IMG_1234.HEIC", "Apple"), ("IMG_1234.DNG", "Apple")] {
                var row = ImageRecord(path: dir.appendingPathComponent(name).path, fingerprint: name)
                row.cameraMake = make
                try await catalog.upsert(row)
            }
            let rows = try await catalog.fetch()
            c.expect(rows.count == 4 && Set(rows.map(\.path)).count == 4, "same-basename Canon / Apple pairs remain independent entries")
            c.expect(rows.filter(\.isRaw).count == 2 && rows.allSatisfy { $0.cameraMake != nil }, "catalog retains make and shared RAW classification")
            // Simulate the pre-Make schema, without manufacturing any camera files.
            let legacyURL = dir.appendingPathComponent("legacy.sqlite")
            var legacy: OpaquePointer?
            guard sqlite3_open(legacyURL.path, &legacy) == SQLITE_OK, let legacy else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_close(legacy) }
            let schema = "CREATE TABLE images (id INTEGER PRIMARY KEY, path TEXT UNIQUE, folder TEXT, filename TEXT, ext TEXT, fingerprint TEXT, capture_date REAL, camera_model TEXT, lens_model TEXT, iso INTEGER, aperture REAL, shutter REAL, focal_length REAL, pixel_width INTEGER, pixel_height INTEGER, rating INTEGER DEFAULT 0, flag INTEGER DEFAULT 0, color_label TEXT DEFAULT '', edit_hash TEXT DEFAULT '', is_raw INTEGER DEFAULT 0)"
            guard sqlite3_exec(legacy, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            let migrated = try Catalog(url: legacyURL)
            var row = ImageRecord(path: "/synthetic/legacy.CR3", fingerprint: "legacy")
            row.cameraMake = "Canon"; row.rating = 4
            try await migrated.upsert(row)
            let recovered = try await migrated.record(path: row.path)
            c.expect(recovered?.cameraMake == "Canon" && recovered?.rating == 4, "pre-Make catalog migrates and stores new metadata")
        }
    }
}
