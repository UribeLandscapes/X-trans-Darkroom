import Foundation
import ImagingCore
import CoreImage
import ImageCanvas
import EditModel
import RawDecode

@MainActor
enum ViewportChecks {
    static func run(_ c: Checks) {
        c.suite("Canvas viewport and comparison math") { c in
            for (image, view) in [(CGSize(width: 6000, height: 4000), CGSize(width: 600, height: 1000)),
                                  (CGSize(width: 4000, height: 6000), CGSize(width: 1000, height: 600))] {
                c.expectClose(CanvasViewport.fitZoom(imageSize: image, viewSizePx: view), 0.1, "opposed aspect Fit")
                c.expectClose(CanvasViewport.fillZoom(imageSize: image, viewSizePx: view), 0.25, "opposed aspect Fill")
            }
            let image = CGSize(width: 6000, height: 4000), view = CGSize(width: 800, height: 600)
            for point in [CGPoint(x: 200, y: 180), CGPoint(x: 400, y: 300), CGPoint(x: 700, y: 550)] {
                var viewport = CanvasViewport(imageSize: image, viewSizePx: view, zoom: 0.5)
                let anchor = viewport.imagePoint(viewPoint: point)
                for factor in [2.0, 1.5, 0.75, 4, 0.5] {
                    viewport.zoom(by: factor, anchoredAt: point)
                    let result = viewport.viewPoint(imagePoint: anchor)
                    c.expect(hypot(result.x-point.x, result.y-point.y) < 0.5, "cursor anchor survives zoom \(factor)")
                }
            }
            for delta in [CGSize(width: 1e6, height: 1e6), CGSize(width: -1e6, height: -1e6), CGSize(width: -1e6, height: 1e6)] {
                var viewport = CanvasViewport(imageSize: image, viewSizePx: view, zoom: 1)
                viewport.pan(byViewDelta: delta)
                let r = viewport.visibleImageRect
                c.expect(r.minX >= 0 && r.minY >= 0 && r.maxX <= image.width && r.maxY <= image.height, "large pan stays inside image")
                c.expect(r.size == view, "large pan does not reveal surround")
            }
            var wide = CanvasViewport(imageSize: CGSize(width: 2000, height: 200), viewSizePx: view, zoom: 1)
            wide.pan(byViewDelta: CGSize(width: 10000, height: 10000))
            c.expectClose(wide.center.y, 0.5, "pan keeps the smaller axis centered")
            c.expectClose(wide.visibleImageRect.width, view.width, "pan clamps the larger axis")
            let small = CanvasViewport(imageSize: CGSize(width: 100, height: 80), viewSizePx: view, zoom: 1, center: .zero)
            c.expect(small.center == CGPoint(x: 0.5, y: 0.5), "small image centers on both axes")
            c.expect(small.visibleImageRect.size == CGSize(width: 100, height: 80), "small image visible at original size")
            c.expect(!small.pannable, "small image cannot pan")
            for scale in [1.0, 2.0] {
                let vp = CanvasViewport(imageSize: image, viewSizePx: CGSize(width: 800*scale, height: 600*scale), zoom: 1)
                c.expectClose(vp.visibleImageRect.width, 800*scale, "1:1 backing width")
                c.expectClose(vp.visibleImageRect.minX, 3000-400*scale, "1:1 source x")
                c.expectClose(vp.visibleImageRect.minY, 2000-300*scale, "1:1 source y")
            }
            for zoom in [0.1, 0.5, 1, 4, 16] {
                let vp = CanvasViewport(imageSize: image, viewSizePx: view, zoom: zoom, center: CGPoint(x: 0.6, y: 0.4))
                for ratio in [0.1, 0.25, 0.5, 1.0] {
                    let p = CGPoint(x: 0.57*image.width, y: 0.42*image.height)
                    let scale = vp.renderedScale(renderedWidth: image.width*ratio)
                    let mapped = CGPoint(x: view.width/2 + (p.x*ratio-vp.center.x*image.width*ratio)*scale,
                                         y: view.height/2 - (p.y*ratio-vp.center.y*image.height*ratio)*scale)
                    let expected = vp.viewPoint(imagePoint: p)
                    c.expect(hypot(mapped.x-expected.x, mapped.y-expected.y) < 1e-6, "proxy/full mapping at \(zoom), ratio \(ratio)")
                }
            }
            for minimum in [0.01, 0.0625] {
                for zoom in [minimum, 0.1, 0.5, 1, 4, 16] {
                    let f = CanvasViewport.sliderFraction(zoom: zoom, minimum: minimum)
                    c.expectClose(CanvasViewport.sliderZoom(fraction: f, minimum: minimum), zoom, "log slider round trip", tolerance: 1e-6)
                }
                c.expectClose(CanvasViewport.sliderZoom(fraction: -1, minimum: minimum), minimum, "slider lower clamp")
                c.expectClose(CanvasViewport.sliderZoom(fraction: 2, minimum: minimum), 16, "slider upper clamp")
                c.expectClose(CanvasViewport.sliderFraction(zoom: 100, minimum: minimum), 1, "value upper clamp")
                c.expectClose(CanvasViewport.sliderFraction(zoom: 0, minimum: minimum), 0, "value lower clamp")
            }
            c.expectClose(CanvasViewport(imageSize: image, viewSizePx: view, zoom: 100).zoom, 16, "viewport upper clamp")
            c.expectClose(CanvasViewport(imageSize: image, viewSizePx: view, zoom: 0).zoom, 0.0625, "viewport lower clamp")
            for mode in [BeforeAfterMode.sideBySide, .topBottom] {
                let panes = mode.panes(in: view)
                c.expect(panes.count == 2 && !panes[0].intersects(panes[1]), "comparison panes do not overlap")
                if mode.isVertical {
                    c.expectClose(panes[1].minY-panes[0].maxY, 1, "horizontal gap is one backing pixel")
                    c.expectClose(panes[1].maxY, view.height, "panes partition height")
                } else {
                    c.expectClose(panes[1].minX-panes[0].maxX, 1, "vertical gap is one backing pixel")
                    c.expectClose(panes[1].maxX, view.width, "panes partition width")
                }
            }
            c.expectClose(BeforeAfterMode.divider(-1), 0.05, "divider minimum")
            c.expectClose(BeforeAfterMode.divider(2), 0.95, "divider maximum")
            c.expectClose(BeforeAfterMode.divider(0.5), 0.5, "divider default")
            for zoom in [0.1, 0.25, 0.25001, 1.0] {
                c.expect(CanvasViewport.needsFullFrame(displayedScale: zoom, proxyRatio: 0.25) == (zoom > 0.25), "detail resolution threshold \(zoom)")
            }
            let root = Checks.repoRoot()
            for file in ["App/EditorView.swift", "App/CanvasArea.swift", "ImageCanvas/RenderCoordinator.swift"] {
                let source = try String(contentsOf: root.appendingPathComponent("Sources/"+file), encoding: .utf8)
                c.expect(!source.contains("expansion.detail") && !source.contains("inspectionEnabled"), "\(file): Detail expansion does not control rendering")
            }
            let expansion = try String(contentsOf: root.appendingPathComponent("Sources/App/InspectorSection.swift"), encoding: .utf8)
            let active = expansion.components(separatedBy: "var activeTools").last?.components(separatedBy: "\n").first ?? ""
            c.expect(!active.contains("detail"), "active canvas tools exclude Detail")
        }
        c.suite("Before render cache and geometry (no readback)") { c in
            let coordinator = RenderCoordinator(decoder: ViewportDecoder())
            coordinator.open(URL(fileURLWithPath: "/before-a.png"), canvasLongEdge: 150)
            coordinator.displayedScale = 1
            var after = EditStack()
            after.geometry.cropWidth = 0.5
            coordinator.renderInteractive(after)
            let before = coordinator.beforeImage
            c.expect(before != nil && before?.extent.size == CGSize(width: 600, height: 400), "before retains uncropped source extent")
            c.expect(coordinator.displayPixelSize.width == 300, "after viewport uses cropped full-resolution extent")
            after.light.exposure = 1
            coordinator.renderInteractive(after)
            c.expect(coordinator.beforeImage === before, "after edits reuse cached before graph")
            coordinator.rebuildProxy(canvasLongEdge: 300)
            coordinator.renderInteractive(after)
            c.expect(coordinator.beforeImage === before, "resize retains full-resolution before cache")
            coordinator.cropEditing = true
            coordinator.renderInteractive(after)
            c.expect(coordinator.displayPixelSize.width == 600, "crop editing restores full canvas coordinates")
            var changedBefore = EditStack()
            changedBefore.geometry.rotation = 1
            coordinator.setBeforeStack(changedBefore)
            coordinator.renderInteractive(after)
            c.expect(coordinator.beforeImage?.extent.size == CGSize(width: 400, height: 600), "before stack invalidates cached geometry")
            coordinator.open(URL(fileURLWithPath: "/before-b.png"), canvasLongEdge: 150)
            coordinator.renderInteractive(EditStack())
            c.expect(coordinator.beforeImage?.extent.size == CGSize(width: 600, height: 400), "new source resets before stack and cache")
        }
    }
}

private struct ViewportDecoder: RawDecoder {
    func canDecode(_ url: URL) -> Bool { true }
    func decode(_ url: URL, scale: DecodeScale) throws -> DecodedFrame {
        let size = CGSize(width: 600, height: 400)
        let image = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18))
            .cropped(to: CGRect(origin: .zero, size: size))
        return DecodedFrame(image: image, pixelSize: size, metadata: CaptureMetadata())
    }
}
