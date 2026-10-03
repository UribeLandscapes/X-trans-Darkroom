import Foundation
import CoreGraphics
import AppKit
import SwiftUI
import ImagingCore
import StudioTheme

@MainActor
enum StudioOverlayChecks {
    static func run(_ c: Checks) {
        c.suite("Studio theme and canvas overlays") { c in
            // Every icon must resolve to a real SF Symbol - the raster-bitmap checks that
            // used to live here no longer apply now that icons are system-provided.
            for icon in StudioIcon.allCases {
                let image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil)
                c.expect(image != nil, "\(icon.rawValue): SF Symbol \"\(icon.symbolName)\" resolves")
            }

            // The canvas surround levels are a measurement baseline other checks below (and
            // ImageCanvas itself, indirectly, via the App layer) depend on. A restyle must
            // never change these two numbers.
            c.expect(Studio.surroundLevel(focused: false) == 0.09, "unfocused surround is exactly 0.09")
            c.expect(Studio.surroundLevel(focused: true) == 0.18, "focused surround is exactly 0.18")

            // Palette-zoning source scan (Build plan §9, carried forward): glass belongs on
            // outer chrome only, and `chromeGlass` is the sole point of entry for it.
            let root = Checks.repoRoot()
            let themeDir = "Sources/StudioTheme/"
            var glassEffectOffenders: [String] = []
            var chromeGlassOffenders: [String] = []
            var materialOffenders: [String] = []
            let canvasAdjacentFiles = [
                "CropOverlay.swift", "HistogramView.swift", "ToneCurveView.swift",
                "ColorMixView.swift", "CameraPanelView.swift", "GeometryView.swift", "OpticsView.swift",
                "InspectorView.swift", "InspectorSection.swift", "CanvasBar.swift", "CanvasArea.swift", "CanvasInfoOverlay.swift", "ShortcutSheet.swift", "SliderKeyboard.swift", "DevelopKeys.swift", "DevelopCommands.swift", "EditorSettings.swift", "ClippingOverlay.swift", "ColorTreatment.swift", "WhiteBalanceSampling.swift", "SpatialStages.swift", "ThumbnailRendering.swift"
            ]
            // Inspector and canvas chrome must stay solid; sidebar and toolbar may use materials.
            let materialScanFiles = ["InspectorView.swift", "InspectorSection.swift", "CanvasBar.swift", "CanvasArea.swift", "CanvasInfoOverlay.swift", "ShortcutSheet.swift", "SliderKeyboard.swift", "DevelopKeys.swift", "DevelopCommands.swift", "EditorSettings.swift", "ClippingOverlay.swift", "ColorTreatment.swift", "WhiteBalanceSampling.swift", "SpatialStages.swift", "ThumbnailRendering.swift"]
            if let walker = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
                while let url = walker.nextObject() as? URL {
                    guard url.pathExtension == "swift" else { continue }
                    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    // Skip this check file itself - it names the token in its own assertion text.
                    if url.lastPathComponent == "StudioOverlayChecks.swift" { continue }
                    if source.contains(".glassEffect(") && !relative.hasPrefix(themeDir) {
                        glassEffectOffenders.append(relative)
                    }
                    if canvasAdjacentFiles.contains(url.lastPathComponent) && source.contains("chromeGlass") {
                        chromeGlassOffenders.append(url.lastPathComponent)
                    }
                    if materialScanFiles.contains(url.lastPathComponent) && source.contains(".background(.") {
                        materialOffenders.append(url.lastPathComponent)
                    }
                }
            }
            c.expect(glassEffectOffenders.isEmpty,
                     "'.glassEffect(' appears only under \(themeDir)\(glassEffectOffenders.isEmpty ? "" : " - \(glassEffectOffenders)")")
            c.expect(chromeGlassOffenders.isEmpty,
                     "chromeGlass is not used in canvas-adjacent files\(chromeGlassOffenders.isEmpty ? "" : " - \(chromeGlassOffenders)")")
            c.expect(materialOffenders.isEmpty,
                     "no '.background(.' material in the inspector file(s)\(materialOffenders.isEmpty ? "" : " - \(materialOffenders)")")

            let crop = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.5)
            for size in [CGSize(width: 6000, height: 4000), CGSize(width: 3000, height: 5000), CGSize(width: 2048, height: 2048)] {
                for zoom: CGFloat in [0.5, 1, 2, 4] {
                    let mapping = CanvasGeometry(imageSize: size, viewSize: CGSize(width: 800, height: 600), zoom: zoom)
                    for p in [CGPoint.zero, CGPoint(x: 400, y: 300), CGPoint(x: 799, y: 599)] {
                        let result = mapping.view(mapping.normalized(p))
                        let error = hypot(result.x-p.x, result.y-p.y)
                        c.expect(error < 1, "\(size) zoom \(zoom): view round-trip error \(error) px")
                    }
                    for handle in CropHandle.allCases {
                        let point = mapping.view(handle.point(in: crop))
                        let hit = CropHandle.hit(CGPoint(x: point.x+2, y: point.y-2), rect: crop, mapping: mapping)
                        c.expect(hit == handle, "\(size) zoom \(zoom): \(handle) hit within 2.83 px")
                    }
                    c.expect(CropHandle.hit(mapping.view(CGPoint(x: crop.midX, y: crop.midY)), rect: crop, mapping: mapping) == nil,
                             "\(size) zoom \(zoom): centre selects 0 handles")
                }
            }
            for handle in CropHandle.allCases {
                for point in [CGPoint(x: -2, y: -2), CGPoint(x: 3, y: 3), CGPoint(x: -2, y: 3), CGPoint(x: 3, y: -2)] {
                    let r = handle.dragging(crop, to: point)
                    c.expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= 1 && r.maxY <= 1 && r.width > 0 && r.height > 0,
                             "\(handle) dragged to \(point): clamped positive rect \(r)")
                }
            }
            let accent = NSColor(Studio.accent).usingColorSpace(.deviceRGB)!
            let normal = NSColor(Studio.surround(focused: false)).usingColorSpace(.deviceRGB)!
            let focus = NSColor(Studio.surround(focused: true)).usingColorSpace(.deviceRGB)!
            c.expectClose(focus.redComponent, focus.greenComponent, "focus R=G")
            c.expectClose(focus.greenComponent, focus.blueComponent, "focus G=B")
            c.expectClose(normal.redComponent, normal.blueComponent, "normal surround R=B")
            c.expect(abs(focus.redComponent-normal.redComponent) > 0.05, "focus changes surround: \(normal.redComponent) → \(focus.redComponent)")
            let after = NSColor(Studio.accent).usingColorSpace(.deviceRGB)!
            c.expect(accent == after, "accent colour is stable across reads")
        }
    }
}
