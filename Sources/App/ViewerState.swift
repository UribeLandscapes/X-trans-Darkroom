import SwiftUI
import ImagingCore
import ImageCanvas
import ShortcutLogic

@MainActor
final class ViewerState: ObservableObject {
    @Published private(set) var zoomMode: ZoomMode = .fit
    @Published private(set) var beforeAfterMode: BeforeAfterMode = .off
    @Published private(set) var viewport = CanvasViewport(imageSize: .zero, viewSizePx: .zero, zoom: 1)
    @Published var infoMode = 0
    @Published var showClipping = false
    @Published var wbPickerActive = false
    func toggleClipping() { showClipping.toggle() }
    @Published var dividerFraction = 0.5
    @Published private(set) var cropEditing = false
    private var lastNonFit = 1.0
    private var canvasSize = CGSize(width: 1, height: 1)
    private var imageSize = CGSize(width: 1, height: 1)
    private var beforeSize = CGSize(width: 1, height: 1)
    var onChange: (() -> Void)?
    var percent: String { String(format: "%.0f%%", viewport.zoom*100) }

    func configure(imageSize: CGSize, beforeSize: CGSize, canvasSize: CGSize) {
        self.imageSize = imageSize; self.beforeSize = beforeSize; self.canvasSize = canvasSize
        rebuild()
    }
    private func rebuild() {
        let imageSize = beforeAfterMode == .before ? beforeSize : self.imageSize
        let size = beforeAfterMode.panes(in: canvasSize)[0].size
        let zoom: Double
        switch zoomMode {
        case .fit: zoom = CanvasViewport.fitZoom(imageSize: imageSize, viewSizePx: size)
        case .fill: zoom = CanvasViewport.fillZoom(imageSize: imageSize, viewSizePx: size)
        case .custom(let value): zoom = value
        }
        viewport = CanvasViewport(imageSize: imageSize, viewSizePx: size, zoom: zoom, center: viewport.center)
    }
    func viewport(for size: CGSize) -> CanvasViewport {
        // Fresh-open geometry can differ: Fit gives each image its own fit scale;
        // custom zoom shares screen pixels per source pixel for honest detail comparison.
        let zoom = zoomMode == .fit ? CanvasViewport.fitZoom(imageSize: size, viewSizePx: viewport.viewSizePx) : viewport.zoom
        return CanvasViewport(imageSize: size, viewSizePx: viewport.viewSizePx, zoom: zoom, center: viewport.center)
    }
    func reset() { wbPickerActive = false; zoomMode = .fit; beforeAfterMode = .off; lastNonFit = 1; dividerFraction = 0.5; rebuild() }
    func setCropEditing(_ enabled: Bool) {
        cropEditing = enabled
        if enabled { wbPickerActive = false; zoomMode = .fit; beforeAfterMode = .off }
        rebuild(); onChange?()
    }
    func zoomToFit() {
        if zoomMode != .fit { lastNonFit = viewport.zoom }
        zoomMode = .fit; rebuild(); onChange?()
    }
    func zoomToFill() { guard !cropEditing else { return }; zoomMode = .fill; rebuild(); lastNonFit = viewport.zoom; onChange?() }
    func zoom1to1() { setZoom(1) }
    func zoomIn() { stepZoom(1) }
    func zoomOut() { stepZoom(-1) }
    private func stepZoom(_ direction: Int) {
        guard !cropEditing else { return }
        if let zoom = ShortcutPolicy.zoom(zoomMode == .fit ? nil : viewport.zoom, direction: direction) { setZoom(zoom) }
        else { zoomToFit() }
    }
    func setZoom(_ zoom: Double) {
        input(.zoom(zoom/viewport.zoom, CGPoint(x: viewport.viewSizePx.width/2, y: viewport.viewSizePx.height/2)))
    }
    func toggleZoom() { toggleZoom(at: CGPoint(x: viewport.viewSizePx.width/2, y: viewport.viewSizePx.height/2)) }
    private func toggleZoom(at point: CGPoint) {
        if zoomMode == .fit { input(.zoom(lastNonFit/viewport.zoom, point)) }
        else { lastNonFit = viewport.zoom; zoomToFit() }
    }
    func input(_ input: CanvasInput, using source: CanvasViewport? = nil) {
        if let source, !cropEditing {
            // Cursor anchoring starts in the pane actually under the pointer.
            viewport = source
        }
        guard !cropEditing else { return }
        switch input {
        case .pan(let delta): viewport.pan(byViewDelta: delta)
        case .zoom(let factor, let point):
            viewport.zoom(by: factor, anchoredAt: point)
            zoomMode = .custom(viewport.zoom); lastNonFit = viewport.zoom
        case .toggle(let point): toggleZoom(at: point); return
        }
        rebuild()
        onChange?()
    }
    func toggleBefore() { setBeforeAfter(beforeAfterMode == .before ? .off : .before) }
    func cycleBeforeAfter() {
        let modes = BeforeAfterMode.allCases
        setBeforeAfter(modes[(modes.firstIndex(of: beforeAfterMode)!+1)%modes.count])
    }
    func setBeforeAfter(_ mode: BeforeAfterMode) {
        guard !cropEditing else { return }
        beforeAfterMode = mode; rebuild(); onChange?()
    }
}
