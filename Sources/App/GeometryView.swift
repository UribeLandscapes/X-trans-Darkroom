import SwiftUI
import EditModel
import StudioTheme

/// Build plan §4 (Geometry): crop, straighten, and basic transform.
///
/// The canvas crop overlay lives in App to preserve imaging/chrome isolation.
struct GeometryView: View {
    @Environment(\.freshDefaults) private var defaults
    @Binding var geometry: GeometryAdjustments
    let imageAspect: Double
    let onLive: () -> Void
    let onCommit: () -> Void

    /// Named aspect presets. `nil` means "leave the crop as it is".
    private static let presets: [(String, Double?)] = [
        ("Free", nil), ("Orig", 0), ("1:1", 1.0), ("3:2", 3.0 / 2),
        ("4:3", 4.0 / 3), ("16:9", 16.0 / 9), ("5:4", 5.0 / 4)
    ]

    var body: some View {
        VStack(spacing: StudioMetrics.u(2)) {
            orientationRow

            VStack(alignment: .leading, spacing: 4) {
                Text("Aspect").font(StudioFont.caption()).foregroundStyle(Studio.textSecondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Self.presets, id: \.0) { name, ratio in
                        StudioChip(name, isSelected: false) { apply(aspect: ratio) }
                    }
                }
            }

            StudioSlider("Straighten", value: $geometry.straightenAngle,
                        range: -45...45, neutral: 0,
                        defaultValue: defaults.geometry.straightenAngle, format: .signedDecimal(1),
                        onLive: { _ in onLive() }, onCommit: { _ in onCommit() })

            Rectangle().fill(Studio.separator).frame(height: 1)

            StudioSlider("Vertical", value: $geometry.perspectiveVertical,
                        range: -100...100, neutral: 0,
                        defaultValue: defaults.geometry.perspectiveVertical, format: .integer,
                        onLive: { _ in onLive() }, onCommit: { _ in onCommit() })
            StudioSlider("Horizontal", value: $geometry.perspectiveHorizontal,
                        range: -100...100, neutral: 0,
                        defaultValue: defaults.geometry.perspectiveHorizontal, format: .integer,
                        onLive: { _ in onLive() }, onCommit: { _ in onCommit() })
            StudioSlider("Scale", value: $geometry.transformScale,
                        range: 0.5...2, neutral: 1,
                        defaultValue: defaults.geometry.transformScale, format: .percent,
                        onLive: { _ in onLive() }, onCommit: { _ in onCommit() })

            HStack {
                Text(geometry.hasCrop
                     ? String(format: "Crop %.0f%% × %.0f%%", geometry.cropWidth * 100, geometry.cropHeight * 100)
                     : "Full frame")
                    .font(StudioFont.numeric(10))
                    .foregroundStyle(geometry.hasCrop ? Studio.accent : Studio.textSecondary)
                Spacer()
                StudioButton("Reset") {
                    geometry = .neutral
                    onLive(); onCommit()
                }
            }


        }
    }

    private var orientationRow: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            StudioButton("Rotate left", icon: .rotateLeft) { geometry.rotation = (geometry.rotation + 3) % 4; commitNow() }
            StudioButton("Rotate right", icon: .rotateRight) { geometry.rotation = (geometry.rotation + 1) % 4; commitNow() }
            StudioButton("Flip H", icon: .flipH) { geometry.flipHorizontal.toggle(); commitNow() }
            StudioButton("Flip V", icon: .flipV) { geometry.flipVertical.toggle(); commitNow() }
        }
    }

    private func commitNow() { onLive(); onCommit() }

    /// Centre the largest rectangle of the requested aspect inside the frame.
    /// `nil` leaves the crop alone; `0` means "back to the original aspect", i.e. full frame.
    private func apply(aspect: Double?) {
        guard let aspect else { return }
        if aspect == 0 {
            geometry.cropX = 0; geometry.cropY = 0
            geometry.cropWidth = 1; geometry.cropHeight = 1
            commitNow()
            return
        }
        // Work in normalized units, so the requested ratio has to be expressed relative to
        // the image's own aspect or a 1:1 crop on a 3:2 frame would not come out square.
        let relative = aspect / imageAspect
        var w = 1.0, h = 1.0
        if relative > 1 { h = 1 / relative } else { w = relative }
        geometry.cropWidth = w
        geometry.cropHeight = h
        geometry.cropX = (1 - w) / 2
        geometry.cropY = (1 - h) / 2
        commitNow()
    }
}
