import SwiftUI
import ImageCanvas
import StudioTheme

struct CanvasInfoOverlay: View {
    @ObservedObject var coordinator: RenderCoordinator
    let mode: Int
    var body: some View {
        if mode != 0, coordinator.hasImage {
            VStack(alignment: .leading, spacing: 3) {
                if mode == 1 {
                    Text(coordinator.sourceURL?.lastPathComponent ?? "")
                    Text(String(format: "%.0f × %.0f", coordinator.fullPixelSize.width, coordinator.fullPixelSize.height))
                } else {
                    let m = coordinator.metadata
                    Text(m.cameraModel.isEmpty ? "Camera —" : m.cameraModel)
                    Text(m.shutterSeconds > 0 ? (m.shutterSeconds < 1 ? String(format: "1/%.0f s", 1 / m.shutterSeconds) : String(format: "%.1f s", m.shutterSeconds)) : "Shutter —")
                    Text(String(format: "f/%.1f · ISO %d · %.0f mm", m.aperture, m.iso, m.focalLength))
                }
            }.font(StudioFont.numeric(11)).foregroundStyle(Studio.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .padding(8).background(Studio.background).padding(8)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped().allowsHitTesting(false)
        }
    }
}
