import SwiftUI

/// Solid, opaque rounded-rect surface. This is the workhorse background for every
/// inspector control, text field, and list row - anything that sits near the canvas and so
/// must stay glass-free (see `Glass.swift`).
public extension View {
    func studioSurface(fill: Color = Studio.groupedPanel, corner: CGFloat = StudioMetrics.cornerControl) -> some View {
        background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(fill))
    }

    /// A thin accent-coloured outline, used for selection states (active tab, selected
    /// profile, selected recipe row) instead of the old two-tone bevel.
    func studioSelected(_ isSelected: Bool, corner: CGFloat = StudioMetrics.cornerControl) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isSelected ? Studio.accent : .clear, lineWidth: 2)
        )
    }
}

/// Grouped inset section: SF Symbol + uppercase caption header over solid content. The
/// inspector-panel replacement for the old `PixelPanel`.
public struct StudioSection<Content: View>: View {
    private static var headerIcons: [String: StudioIcon] {
        ["Folders": .folder, "Metadata": .image, "Geometry": .crop, "Detail": .oneToOne,
         "Effects": .grain, "Tone curve": .curve, "Color": .eyedropper, "Optics": .settings,
         "Render budget": .histogram, "Camera": .camera]
    }
    let title: String
    @ViewBuilder let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: StudioMetrics.u(1.25)) {
            HStack(spacing: 6) {
                if let icon = Self.headerIcons[title] {
                    Image(icon).font(.system(size: 11, weight: .semibold))
                }
                Text(title.uppercased())
                    .font(StudioFont.caption())
                    .kerning(0.5)
            }
            .foregroundStyle(Studio.textSecondary)
            content()
        }
        .padding(StudioMetrics.u(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioSurface(fill: Studio.groupedPanel, corner: StudioMetrics.cornerSection)
    }
}

/// Capsule button. `style` picks the system button style; the label is an SF Symbol plus
/// text via `Label`, matching the iOS toolbar-button idiom.
public struct StudioButton: View {
    public enum Style { case prominent, bordered, plain }
    let title: String
    let icon: StudioIcon?
    let style: Style
    let action: () -> Void

    public init(_ title: String, icon: StudioIcon? = nil, style: Style = .bordered, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.style = style; self.action = action
    }

    @ViewBuilder private var label: some View {
        Group {
            if let icon { Label(title, systemImage: icon.symbolName) } else { Text(title) }
        }
        .font(StudioFont.headline(12))
        .padding(.horizontal, StudioMetrics.u(1.5))
        .padding(.vertical, StudioMetrics.u(0.75))
    }

    public var body: some View {
        switch style {
        case .prominent:
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .tint(Studio.accent)
                .buttonBorderShape(.capsule)
        case .bordered:
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        case .plain:
            Button(action: action) { label }
                .buttonStyle(PlainCapsuleButtonStyle())
        }
    }
}

private struct PlainCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Studio.textPrimary)
            .opacity(configuration.isPressed ? 0.6 : (enabled ? 1 : 0.4))
    }
}

/// Native switch toggle - iOS-style, no custom drawing required on macOS 26.
public struct StudioToggle: View {
    let title: String
    @Binding var isOn: Bool
    let onCommit: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, isOn: Binding<Bool>, onCommit: @escaping () -> Void) {
        self.title = title
        self._isOn = isOn
        self.onCommit = onCommit
    }

    public var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: {
            isOn = $0
            onCommit()
        }))
        .toggleStyle(.switch)
        .tint(Studio.accent)
        .font(StudioFont.body(12))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A row of capsule chips - the segmented-picker replacement used for tab strips, HSL
/// mode, tone-curve channel, and aspect-ratio presets.
public struct StudioChip: View {
    let title: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    public init(_ title: String, isSelected: Bool, tint: Color = Studio.accent, action: @escaping () -> Void) {
        self.title = title; self.isSelected = isSelected; self.tint = tint; self.action = action
    }

    public var body: some View {
        Text(title)
            .font(StudioFont.caption(11))
            .foregroundStyle(isSelected ? Color.white : Studio.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Capsule().fill(isSelected ? tint : Studio.elevated))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }
}

