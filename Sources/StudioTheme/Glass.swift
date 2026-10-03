import SwiftUI

/// The ONLY place in the repo that calls `.glassEffect`.
///
/// Palette-zoning rule, carried over from the retro build plan and still load-bearing:
/// glass/translucency and saturated colour belong only on outer chrome - the title/tool
/// bar, sheets, floating buttons - and NEVER on any surface adjacent to the image
/// (inspector panels, histogram, tone-curve, overlays). A photo viewed through or next to
/// a translucent, colour-shifting surface has its white balance and saturation misjudged;
/// keeping glass off canvas-adjacent chrome is what makes the develop view trustworthy for
/// actual colour decisions. `RetroOverlayChecks` (now `StudioOverlayChecks`) enforces this
/// with a source scan: `chromeGlass` may not appear in CropOverlay, HistogramView,
/// ToneCurveView, ColorMixView, CameraPanelView, GeometryView, or OpticsView.
public extension View {
    func chromeGlass(in shape: some Shape = RoundedRectangle(cornerRadius: StudioMetrics.cornerFloating, style: .continuous)) -> some View {
        self.glassEffect(.regular, in: shape)
    }
}
