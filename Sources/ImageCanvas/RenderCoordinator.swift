import Foundation
import CoreImage
import Metal
import ImagingCore
import EditModel
import RawDecode
import Profiles

/// Build plan §2: the dual-resolution model.
///
/// - Interactive path: renders a pre-scaled proxy sized to the canvas backing store.
///   Coalesced to at most one render per display refresh - events never queue.
/// - Settle path: on pointer-up, or 200 ms of input silence, a cancellable
///   full-resolution render runs on a background context and cross-fades in.
///
/// On the M5 Pro target a ~4 MP proxy through a concatenated Core Image kernel chain
/// leaves substantial headroom inside the 8.3 ms budget; the risk this class manages is
/// not GPU throughput but event pile-up and un-cancelled settle work starving the
/// interactive path.
@MainActor
public final class RenderCoordinator: ObservableObject {

    public static let settleDelay: TimeInterval = 0.200
    public static let interactiveBudgetMS = 8.3
    public static let settleBudgetMS = 350.0

    @Published public private(set) var profileLibrary = ProfileLibrary()

    public var availableProfiles: [CameraProfile] { profileLibrary.profiles(for: metadata.cameraModel) }

    public func importProfile(from url: URL) throws {
        try profileLibrary.importProfile(from: url)
        beforeProxy = nil; beforeFull = nil
    }

    let pipeline = RenderPipeline()
    private let histogramComputer = HistogramComputer()
    private let decoder: any RawDecoder

    /// Full-resolution decoded frame. Held for the settle render and export.
    var fullFrame: DecodedFrame?
    private var beforeFrame: DecodedFrame?
    private var decodedLensCorrection = true
    private var canvasEdge = 2560
    public var cameraSource: CameraSource { metadata.cameraSource }

    private func updateDecode(_ stack: EditStack) {
        guard metadata.supportsBuiltInLensCorrection, let url = sourceURL,
              decodedLensCorrection != stack.optics.builtInLensCorrection else { return }
        do {
            fullFrame = try decoder.decode(url, scale: .full, builtInLensCorrection: stack.optics.builtInLensCorrection)
            decodedLensCorrection = stack.optics.builtInLensCorrection
            rebuildProxy(canvasLongEdge: canvasEdge)
            lastError = nil
        } catch { lastError = String(describing: error) }
    }
    /// Pre-scaled proxy, computed once per source/canvas-size pair and reused for the
    /// whole session - re-downsampling per frame would itself blow the budget.
    private var proxyImage: CIImage?
    private var proxyRatio: Double = 1.0

    @Published public private(set) var displayImage: CIImage?
    @Published public private(set) var beforeImage: CIImage?
    @Published public private(set) var displayPixelSize: CGSize = .zero
    @Published public private(set) var beforePixelSize: CGSize = .zero
    private var beforeStack = EditStack()
    private var beforeProxy: CIImage?
    private var beforeFull: CIImage?

    public func setBeforeStack(_ stack: EditStack) {
        guard stack != beforeStack else { return }
        beforeStack = stack; beforeProxy = nil; beforeFull = nil
    }

    private func renderBefore(full: Bool) -> CIImage? {
        if let cached = full ? beforeFull : beforeProxy { return cached }
        guard let frame = beforeFrame else { return nil }
        let proxy = frame.image.transformed(by: .init(scaleX: proxyRatio, y: proxyRatio))
        let input = DecodedFrameInput(image: full ? frame.image : proxy,
            asShotTemperature: frame.metadata.asShotTemperature, lensCorrection: frame.lensCorrection,
            profile: profileLibrary.resolve(identifier: beforeStack.profileID, cameraModel: frame.metadata.cameraModel))
        let result = pipeline.render(input, stack: beforeStack, proxyRatio: full ? 1 : proxyRatio)
        if full { beforeFull = result } else { beforeProxy = result }
        beforePixelSize = CGSize(width: result.extent.width/(full ? 1 : proxyRatio),
                                 height: result.extent.height/(full ? 1 : proxyRatio))
        return result
    }
    @Published public private(set) var histogram: Histogram = .empty
    @Published public private(set) var asShotSettings: AsShotSettings?
    @Published public private(set) var metadata = CaptureMetadata()
    @Published public private(set) var hasLensCorrection = false
    @Published public private(set) var isSettling = false
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var lastError: String?

    private var settleTask: Task<Void, Never>?
    var settleContext: CIContext

    public init(decoder: any RawDecoder = CoreImageRawDecoder()) {
        self.decoder = decoder
        let device = MTLCreateSystemDefaultDevice()
        self.settleContext = device.map {
            CIContext(mtlDevice: $0, options: [
                .workingColorSpace: WorkingColorSpace.linearWide,
                .cacheIntermediates: false
            ])
        } ?? CIContext(options: [.workingColorSpace: WorkingColorSpace.linearWide])
    }

    // MARK: Loading

    public func open(_ url: URL, canvasLongEdge: Int) {
        settleTask?.cancel()
        beforeFrame = nil; decodedLensCorrection = true
        wbPicking = false
        beforeProxy = nil; beforeFull = nil; beforeImage = nil
        displayImage = nil; displayPixelSize = .zero; beforePixelSize = .zero
        beforeStack = .freshOpenDefault(for: url)
        histogram = .empty
        do {
            let frame = try decoder.decode(url, scale: .full)
            fullFrame = frame
            beforeFrame = frame
            hasLensCorrection = frame.lensCorrection != nil
            metadata = frame.metadata
            asShotSettings = frame.asShotSettings
            sourceURL = url
            lastError = nil
            rebuildProxy(canvasLongEdge: canvasLongEdge)
        } catch {
            lastError = String(describing: error)
            fullFrame = nil
            hasLensCorrection = false
            metadata = CaptureMetadata()
            asShotSettings = nil
            proxyImage = nil
            displayImage = nil
        }
    }

    /// Rebuild the proxy when the canvas resizes. Cheap enough to do on resize-end,
    /// far too expensive to do per frame.
    public func rebuildProxy(canvasLongEdge: Int) {
        canvasEdge = canvasLongEdge
        guard let frame = fullFrame else { return }
        let longEdge = max(frame.pixelSize.width, frame.pixelSize.height)
        guard longEdge > 0 else { return }
        let ratio = min(1.0, Double(canvasLongEdge) / Double(longEdge))
        proxyRatio = ratio
        beforeProxy = nil
        proxyImage = ratio < 1.0
            ? frame.image.transformed(by: .init(scaleX: CGFloat(ratio), y: CGFloat(ratio)))
            : frame.image
    }

    public var displayedScale: Double = 0
    public var usesFullFrame: Bool { CanvasViewport.needsFullFrame(displayedScale: displayedScale, proxyRatio: proxyRatio) }
    public var cropEditing = false
    public var wbPicking = false

    private func previewStack(_ stack: EditStack) -> EditStack {
        var result = stack
        if wbPicking {
            // Disable coordinate warps, including lens warps, for decoded-pixel picking.
            result.geometry = .neutral
            result.optics.correctDistortion = false
            result.optics.removeChromaticAberration = false
        }
        // Keep the uncropped coordinate system stable while chrome handles are dragged.
        if cropEditing {
            result.geometry.cropX = 0; result.geometry.cropY = 0
            result.geometry.cropWidth = 1; result.geometry.cropHeight = 1
        }
        return result
    }

    // MARK: Interactive path

    /// Called at most once per display refresh while a control is being dragged.
    public func renderInteractive(_ stack: EditStack) {
        updateDecode(stack)
        guard let proxy = proxyImage, let frame = fullFrame else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let input = DecodedFrameInput(image: usesFullFrame ? frame.image : proxy, asShotTemperature: frame.metadata.asShotTemperature,
                                      lensCorrection: frame.lensCorrection,
                                      profile: profileLibrary.resolve(identifier: stack.profileID, cameraModel: frame.metadata.cameraModel))
        let rendered = pipeline.render(input, stack: previewStack(stack), proxyRatio: usesFullFrame ? 1 : proxyRatio)
        displayPixelSize = CGSize(width: rendered.extent.width/(usesFullFrame ? 1 : proxyRatio),
                                  height: rendered.extent.height/(usesFullFrame ? 1 : proxyRatio))
        displayImage = rendered
        beforeImage = renderBefore(full: usesFullFrame)
        FrameStats.shared.record(.interactive, seconds: CFAbsoluteTimeGetCurrent() - start)

        // Keep the last whole-image proxy histogram while zoomed. A visible crop would
        // misrepresent exposure, and a second render per gesture would waste work.
        if !usesFullFrame, let h = histogramComputer.compute(rendered) { histogram = h }
    }

    // MARK: Settle path

    /// Called on interaction end. Supersedes any in-flight settle render.
    public func scheduleSettle(_ stack: EditStack) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            guard !Task.isCancelled else { return }
            await self?.renderSettle(stack)
        }
    }

    private func renderSettle(_ stack: EditStack) async {
        updateDecode(stack)
        guard let frame = fullFrame else { return }
        isSettling = true
        defer { isSettling = false }

        let input = DecodedFrameInput(image: frame.image,
                                      asShotTemperature: frame.metadata.asShotTemperature,
                                      lensCorrection: frame.lensCorrection,
                                      profile: profileLibrary.resolve(identifier: stack.profileID, cameraModel: frame.metadata.cameraModel))
        let start = CFAbsoluteTimeGetCurrent()
        let rendered = pipeline.render(input, stack: previewStack(stack), proxyRatio: 1.0)
        guard !Task.isCancelled else { return }
        displayPixelSize = rendered.extent.size
        displayImage = rendered
        // These lazy graphs are cached per source/stack/resolution. Resize invalidates
        // only the proxy; the full-resolution before graph settles just once.
        beforeImage = renderBefore(full: true)
        FrameStats.shared.record(.settle, seconds: CFAbsoluteTimeGetCurrent() - start)
    }

    public var hasImage: Bool { fullFrame != nil }
    public var fullPixelSize: CGSize { fullFrame?.pixelSize ?? .zero }
    public var currentProxyRatio: Double { proxyRatio }
}
