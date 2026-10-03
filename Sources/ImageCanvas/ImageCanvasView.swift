import SwiftUI
import AppKit
import MetalKit
import CoreImage
import ImagingCore

/// Build plan §3 and §9: the image canvas.
///
/// This view owns its CAMetalLayer, its colour space and its drawable, and it deliberately
/// has NO access to the chrome - the ImageCanvas target does not depend on StudioTheme,
/// so no palette, bitmap font, dither pattern or pixelation shader can reach the photo.
/// Whatever the surrounding UI looks like, what is drawn here is the full-fidelity image.
public struct ImageCanvasView: NSViewRepresentable {

    private let image: CIImage?
    private let viewport: CanvasViewport
    private let surround: Double
    private let inputEnabled: Bool
    private let showClipping: Bool
    private let pickerActive: Bool
    private let onPick: (CGPoint) -> Void
    private let onInput: (CanvasInput) -> Void

    public init(image: CIImage?, viewport: CanvasViewport, surround: Double = 0.09,
                inputEnabled: Bool = true, showClipping: Bool = false, pickerActive: Bool = false,
                onPick: @escaping (CGPoint) -> Void = { _ in }, onInput: @escaping (CanvasInput) -> Void) {
        self.image = image; self.viewport = viewport; self.surround = surround
        self.showClipping = showClipping; self.pickerActive = pickerActive; self.onPick = onPick
        self.inputEnabled = inputEnabled; self.onInput = onInput
    }
    public func makeNSView(context: Context) -> CanvasMTKView { CanvasMTKView() }
    public func updateNSView(_ view: CanvasMTKView, context: Context) {
        view.viewport = viewport; view.surround = surround
        view.inputEnabled = inputEnabled; view.onInput = onInput
        view.pickerActive = pickerActive; view.onPick = onPick
        view.display(image: showClipping ? image.map(ClippingOverlay.apply) : image)
        view.window?.invalidateCursorRects(for: view)
    }
}

public enum CanvasInput {
    case pan(CGSize), zoom(Double, CGPoint), toggle(CGPoint)
}

public final class CanvasMTKView: MTKView {
    private var ciContext: CIContext?
    private var current: CIImage?
    public var viewport = CanvasViewport(imageSize: .zero, viewSizePx: .zero, zoom: 1)
    public var surround = 0.09
    public var inputEnabled = true
    public var onInput: ((CanvasInput) -> Void)?
    public var pickerActive = false
    public var onPick: ((CGPoint) -> Void)?
    private var dragging = false

    public init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)

        // Full precision, wide gamut, colour managed to the display. None of this is
        // negotiable for a photo editor and none of it is affected by the app's styling.
        colorPixelFormat = .rgba16Float
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        layer?.isOpaque = true

        if let device {
            ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: WorkingColorSpace.linearWide,
                .cacheIntermediates: false,
                .highQualityDownsample: true
            ])
        }
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = false
            metalLayer.colorspace = WorkingColorSpace.displayP3
        }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    public func display(image: CIImage?) {
        current = image
        setNeedsDisplay(bounds)
    }

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x*backing, y: (bounds.height-p.y)*backing)
    }
    public override func resetCursorRects() {
        if pickerActive { addCursorRect(bounds, cursor: .crosshair); return }
        if inputEnabled && viewport.pannable { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) }
    }
    public override func scrollWheel(with event: NSEvent) {
        guard inputEnabled else { return }
        if event.modifierFlags.contains(.command) {
            onInput?(.zoom(exp(-event.scrollingDeltaY * 0.01), point(event)))
        } else if viewport.pannable {
            onInput?(.pan(CGSize(width: event.scrollingDeltaX*backing, height: event.scrollingDeltaY*backing)))
        }
    }
    public override func magnify(with event: NSEvent) {
        if inputEnabled { onInput?(.zoom(max(0.01, 1+event.magnification), point(event))) }
    }
    public override func mouseDown(with event: NSEvent) {
        guard inputEnabled else { return }
        if pickerActive { onPick?(viewport.imagePoint(viewPoint: point(event))); return }
        if event.clickCount == 2 { onInput?(.toggle(point(event))); return }
        dragging = viewport.pannable
        if dragging { NSCursor.closedHand.set() }
    }
    public override func mouseDragged(with event: NSEvent) {
        if dragging && inputEnabled { onInput?(.pan(CGSize(width: event.deltaX*backing, height: event.deltaY*backing))) }
    }
    public override func mouseUp(with event: NSEvent) {
        dragging = false
        window?.invalidateCursorRects(for: self)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable,
              let ciContext,
              let queue = device?.makeCommandQueue(),
              let buffer = queue.makeCommandBuffer()
        else { return }

        let target = CGRect(origin: .zero, size: drawableSize)

        // Neutral surround (§9): a mid-dark achromatic ground, never a saturated retro
        // colour, because adjacent colour makes white-balance judgement unreliable.
        let background = CIImage(color: CIColor(red: surround, green: surround, blue: surround)).cropped(to: target)

        var composite = background
        if let image = current, !image.extent.isInfinite, !image.extent.isEmpty {
            let ratio = image.extent.width / viewport.imageSize.width
            let scale = viewport.renderedScale(renderedWidth: image.extent.width)
            let visible = viewport.visibleImageRect
            let region = CGRect(x: image.extent.minX + visible.minX*ratio,
                                y: image.extent.minY + visible.minY*ratio,
                                width: visible.width*ratio, height: visible.height*ratio)
            // Crop the output graph, preserving neighbourhood filters' input halos.
            let transformed = image.cropped(to: region)
                .transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
                .transformed(by: .init(scaleX: scale, y: scale))
                .transformed(by: .init(translationX: target.midX - viewport.center.x*viewport.imageSize.width*viewport.zoom,
                                       y: target.midY - viewport.center.y*viewport.imageSize.height*viewport.zoom))
            composite = transformed.composited(over: background).cropped(to: target)
        }

        ciContext.render(composite,
                         to: drawable.texture,
                         commandBuffer: buffer,
                         bounds: target,
                         colorSpace: WorkingColorSpace.displayP3)
        buffer.present(drawable)
        buffer.commit()
    }
}
