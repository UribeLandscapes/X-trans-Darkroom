import SwiftUI
import EditModel
import StudioTheme

/// Build plan §4: the eight-band HSL mixer. Global only — this adjusts a colour range
/// across the whole frame, which is not a mask and does not become one.
struct HSLMixView: View {
    @Environment(\.freshDefaults) private var defaults
    @Binding var mix: HSLMix
    let onLive: () -> Void
    let onCommit: () -> Void

    @State private var mode: Mode = .saturation
    enum Mode: String, CaseIterable { case hue = "Hue", saturation = "Sat", luminance = "Lum" }

    // Swatches use each band's own centre hue, so the row reads as a colour picker rather
    // than a list of words.
    private func swatch(_ color: HSLColor) -> Color {
        let rgb = HSV.toRGB(color.centerHue, 0.85, 0.95)
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    var body: some View {
        VStack(spacing: StudioMetrics.u(1)) {
            HStack(spacing: 4) {
                ForEach(Mode.allCases, id: \.self) { m in
                    StudioChip(m.rawValue, isSelected: mode == m) { mode = m }
                }
            }
            ForEach(HSLColor.allCases, id: \.self) { color in
                HStack(spacing: StudioMetrics.u(1)) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(swatch(color))
                        .frame(width: StudioMetrics.u(2), height: StudioMetrics.u(2))
                    StudioSlider(
                        color.rawValue,
                        value: binding(for: color),
                        range: -100...100,
                        neutral: 0,
                        defaultValue: defaultValue(for: color), format: .integer,
                        onLive: { _ in onLive() },
                        onCommit: { _ in onCommit() })
                }
            }
        }
    }

    private func defaultValue(for color: HSLColor) -> Double {
        let band = defaults.hsl[color]
        switch mode {
        case .hue: return band.hue
        case .saturation: return band.saturation
        case .luminance: return band.luminance
        }
    }

    private func binding(for color: HSLColor) -> Binding<Double> {
        Binding(
            get: {
                let band = mix[color]
                switch mode {
                case .hue: return band.hue
                case .saturation: return band.saturation
                case .luminance: return band.luminance
                }
            },
            set: { value in
                var band = mix[color]
                switch mode {
                case .hue: band.hue = value
                case .saturation: band.saturation = value
                case .luminance: band.luminance = value
                }
                mix[color] = band
            })
    }
}

/// Three-way colour grading. Each zone gets a hue and a saturation; blending and balance
/// control how the zones overlap.
struct ColorGradingView: View {
    @Environment(\.freshDefaults) private var defaults
    @Binding var grading: ColorGrading
    let onLive: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: StudioMetrics.u(2)) {
            zone("Shadows", hue: $grading.shadowHue, saturation: $grading.shadowSaturation,
                 defaultHue: defaults.grading.shadowHue, defaultSaturation: defaults.grading.shadowSaturation)
            zone("Midtones", hue: $grading.midtoneHue, saturation: $grading.midtoneSaturation,
                 defaultHue: defaults.grading.midtoneHue, defaultSaturation: defaults.grading.midtoneSaturation)
            zone("Highlights", hue: $grading.highlightHue, saturation: $grading.highlightSaturation,
                 defaultHue: defaults.grading.highlightHue, defaultSaturation: defaults.grading.highlightSaturation)
            Rectangle().fill(Studio.separator).frame(height: 1)
            slider("Blending", $grading.blending, 0...100, neutral: defaults.grading.blending)
            slider("Balance", $grading.balance, -100...100, neutral: defaults.grading.balance)
        }
    }

    private func zone(_ title: String, hue: Binding<Double>, saturation: Binding<Double>,
                      defaultHue: Double, defaultSaturation: Double) -> some View {
        let rgb = HSV.toRGB(hue.wrappedValue, max(0.15, saturation.wrappedValue / 100), 0.95)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: StudioMetrics.u(1)) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                    .frame(width: StudioMetrics.u(2), height: StudioMetrics.u(2))
                Text(title)
                    .font(StudioFont.caption())
                    .foregroundStyle(Studio.textSecondary)
            }
            slider("Hue", hue, 0...360, neutral: defaultHue)
            slider("Sat", saturation, 0...100, neutral: defaultSaturation)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, neutral: Double = 0) -> some View {
        StudioSlider(label, value: value, range: range, neutral: neutral, defaultValue: neutral, format: .integer,
                    onLive: { _ in onLive() }, onCommit: { _ in onCommit() })
    }
}
