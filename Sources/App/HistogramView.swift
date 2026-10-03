import SwiftUI
import ImageCanvas
import StudioTheme

/// This is chrome, so it is restyled to modern flat bars - but it plots real bin data at
/// full precision straight from the pipeline. Styled presentation, unstyled numbers.
struct HistogramView: View {
    let histogram: Histogram
    @ObservedObject var viewer: ViewerState
    private let bars = 128

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let step = Histogram.binCount / bars
                let w = size.width / CGFloat(bars)

                func draw(_ data: [Float], _ color: Color) {
                    for i in 0..<bars {
                        // Peak within the group, not mean: a single blown channel should
                        // stay visible rather than being averaged away.
                        var peak: Float = 0
                        for j in 0..<step { peak = max(peak, data[i * step + j]) }
                        let h = min(1, CGFloat(peak)) * size.height
                        guard h > 0.5 else { continue }
                        ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: size.height - h,
                                             width: max(1, w - 0.5), height: h)),
                                 with: .color(color))
                    }
                }

                // Additive-ish layering so overlaps read as lighter, the way a scope does.
                draw(histogram.red,   Color(nsColor: .systemRed).opacity(0.55))
                draw(histogram.green, Color(nsColor: .systemGreen).opacity(0.55))
                draw(histogram.blue,  Color(nsColor: .systemBlue).opacity(0.55))
                draw(histogram.luma,  Studio.textPrimary.opacity(0.30))
            }
            .frame(height: StudioMetrics.u(8))
            .clipShape(RoundedRectangle(cornerRadius: StudioMetrics.cornerControl, style: .continuous))
            .studioSurface(fill: Studio.sunken)

            HStack {
                clipLabel("Shadows", histogram.shadowClipping)
                Spacer()
                clipLabel("Highlights", histogram.highlightClipping)
            }
        }
        .accessibilityLabel("RGB histogram")
    }

    private func clipLabel(_ title: String, _ fraction: Float) -> some View {
        // 0.5% of the frame at an endpoint is the threshold worth warning about; below that
        // every normal photo would light up the indicator and it would mean nothing.
        let clipping = fraction > 0.005
        return Button(action: viewer.toggleClipping) { HStack(spacing: 4) {
            Image(systemName: viewer.showClipping ? "triangle.fill" : "triangle")
                .foregroundStyle(clipping ? Studio.textPrimary : Studio.textSecondary)
                .frame(width: 6, height: 6)
            Text("\(title) \(String(format: "%.1f%%", fraction * 100))")
                .font(StudioFont.numeric(9))
                .foregroundStyle(clipping ? Studio.textPrimary : Studio.textSecondary)
        } }.buttonStyle(.plain).accessibilityLabel("Show Clipping: " + title)
            .accessibilityValue(viewer.showClipping ? "On" : "Off")
    }
}
