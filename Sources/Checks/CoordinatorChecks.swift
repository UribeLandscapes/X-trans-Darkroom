import Foundation
import CoreImage
import ImagingCore
import ImageCanvas
import EditModel
import RawDecode

/// RenderCoordinator settle/histogram behavior. Uses a synthetic decoder so the checks
/// need no RAW fixture; sleeps are only used to prove a task did NOT publish.
enum CoordinatorChecks {
    @MainActor
    static func run(_ c: Checks) async {
        await c.suite("Settle renders: stale settle never replaces a newer edit") { c in
            let coordinator = RenderCoordinator(decoder: HalfDecoder())
            coordinator.open(URL(fileURLWithPath: "/settle-a.png"), canvasLongEdge: 150)
            var stackA = EditStack(); stackA.light.exposure = 1
            var stackB = EditStack(); stackB.light.exposure = -1

            coordinator.renderInteractive(stackA)
            let before = coordinator.displayImage
            coordinator.scheduleSettle(stackA)
            try await Task.sleep(for: .seconds(RenderCoordinator.settleDelay + 0.4))
            c.expect(coordinator.displayImage !== before, "control: an undisturbed settle publishes its full-resolution render")

            coordinator.scheduleSettle(stackA)
            coordinator.renderInteractive(stackB)
            let interactive = coordinator.displayImage
            try await Task.sleep(for: .seconds(RenderCoordinator.settleDelay + 0.4))
            c.expect(coordinator.displayImage === interactive, "settle scheduled for stack A does not publish after interactive render of stack B")
            c.expect(!coordinator.isSettling, "stale settle leaves isSettling false")
        }
        await c.suite("Settle renders: commit-then-interactive ordering still settles") { c in
            let coordinator = RenderCoordinator(decoder: HalfDecoder())
            coordinator.open(URL(fileURLWithPath: "/settle-order.png"), canvasLongEdge: 150)
            var stack = EditStack(); stack.light.exposure = 1

            // Reset All / camera change used to schedule the settle (commit) and then render.
            coordinator.scheduleSettle(stack)
            coordinator.renderInteractive(stack)
            let interactive = coordinator.displayImage
            try await Task.sleep(for: .seconds(RenderCoordinator.settleDelay + 0.4))
            c.expect(coordinator.displayImage !== interactive, "settle for the same stack still publishes after an interactive render of it")

            coordinator.displayedScale = 1
            var dark = EditStack(); dark.light.exposure = -2
            var bright = EditStack(); bright.light.exposure = 2
            coordinator.renderInteractive(dark)
            let darkHistogram = coordinator.histogram
            coordinator.scheduleSettle(bright)
            coordinator.renderInteractive(bright)
            try await Task.sleep(for: .seconds(RenderCoordinator.settleDelay + 0.4))
            c.expect(coordinator.histogram != darkHistogram, "zoomed histogram refreshes from the settle after commit-then-render")
        }
        await c.suite("Histogram: whole image stays current while zoomed") { c in
            let coordinator = RenderCoordinator(decoder: HalfDecoder())
            coordinator.open(URL(fileURLWithPath: "/hist-a.png"), canvasLongEdge: 150)
            coordinator.displayedScale = 1
            c.expect(coordinator.usesFullFrame, "precondition: 100% zoom uses the full frame")
            var stack = EditStack(); stack.light.exposure = 1
            coordinator.renderInteractive(stack)
            c.expect(coordinator.histogram != .empty, "histogram updates after an edit while zoomed")
            c.expect(coordinator.histogramSourceSize == CGSize(width: 150, height: 100),
                     "zoomed histogram reads the whole-image proxy, not the full-frame crop (got \(coordinator.histogramSourceSize))")
            let zoomed = coordinator.histogram
            coordinator.displayedScale = 0
            coordinator.renderInteractive(stack)
            c.expect(zoomed == coordinator.histogram, "zoomed and fit histograms agree for the same stack")

            coordinator.displayedScale = 1
            var darker = EditStack(); darker.light.exposure = -2
            coordinator.scheduleSettle(darker)
            try await Task.sleep(for: .seconds(RenderCoordinator.settleDelay + 0.4))
            c.expect(coordinator.histogram != zoomed, "settle refreshes the histogram")
            c.expect(coordinator.histogramSourceSize == CGSize(width: 150, height: 100), "settle histogram also reads the whole-image proxy")
        }
    }
}

/// Left half black, right half white; 600x400.
private struct HalfDecoder: RawDecoder {
    func canDecode(_ url: URL) -> Bool { true }
    func decode(_ url: URL, scale: DecodeScale) throws -> DecodedFrame {
        let size = CGSize(width: 600, height: 400)
        let left = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        let right = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: CGRect(x: 300, y: 0, width: 300, height: 400))
        return DecodedFrame(image: right.composited(over: left), pixelSize: size, metadata: CaptureMetadata())
    }
}
