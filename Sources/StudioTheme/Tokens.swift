import SwiftUI
import AppKit

/// Modern Apple look, iOS/iPadOS 26-27 style: Liquid Glass on outer chrome, solid
/// neutral surfaces everywhere else.
///
/// Palette zoning is a deliberate rule, not a stylistic accident: the surround immediately
/// around the image stays achromatic, because saturated colour adjacent to a photo makes
/// white-balance and saturation judgement unreliable. The single accent hue is reserved for
/// the outer chrome and for selection/affordance states, never for the canvas surround.
public enum Studio {

    // One accent, Apple system-blue style, plus the two semantic colours everything else
    // borrows from.
    public static let accent = Color.accentColor
    public static let destructive = Color(nsColor: .systemRed)
    public static let warning = Color(nsColor: .systemOrange)
    public static let success = Color(nsColor: .systemGreen)

    // Achromatic surface ramp - everything structural, and everything near the canvas.
    public static let background  = Color(white: 0.05)
    public static let groupedPanel = Color(white: 0.13)
    public static let elevated    = Color(white: 0.19)
    public static let sunken      = Color(white: 0.08)
    public static let separator   = Color(white: 0.30)
    /// Neutral selection fill for controls that sit beside the photo (e.g. the inspector tab
    /// strip) - never the saturated accent, per §9 palette zoning.
    public static let neutralSelection = Color(white: 0.34)
    public static let textPrimary   = Color(white: 0.92)
    public static let textSecondary = Color(white: 0.62)
    public static let textTertiary  = Color(white: 0.42)

    /// The canvas surround. Referenced by the app shell, never by ImageCanvas itself.
    /// These two numbers are a measurement baseline - do not change them as part of a
    /// restyle; the canvas geometry checks assume exactly 0.09 / 0.18.
    public static func surroundLevel(focused: Bool) -> Double { focused ? 0.18 : 0.09 }
    public static func surround(focused: Bool) -> Color { Color(white: surroundLevel(focused: focused)) }
    public static let canvasSurround = Color(white: 0.09)
}

/// 8-point spacing grid plus the corner radii used across chrome, sections, and floating
/// controls. Continuous ("squircle") corners throughout, matching iOS/iPadOS 26.
public enum StudioMetrics {
    public static let unit: CGFloat = 8
    public static func u(_ n: CGFloat) -> CGFloat { unit * n }
    public static let hairline: CGFloat = 1
    public static let panelWidth: CGFloat = 288

    public static let cornerControl: CGFloat = 8
    public static let cornerSection: CGFloat = 12
    public static let cornerFloating: CGFloat = 20
}

/// Type roles: SF Pro for prose and labels, SF Mono-style monospaced digits for numeric
/// readouts (exposure values, histogram clip percentages, render-budget stats).
public enum StudioFont {
    // Collection view cells need native fonts without a hosting view per label.
    public static func appKitLabel(_ size: CGFloat = 11) -> NSFont {
        .systemFont(ofSize: size, weight: .semibold)
    }
    public static func appKitBody(_ size: CGFloat = 12) -> NSFont {
        .systemFont(ofSize: size, weight: .regular)
    }

    /// Section headers, tab titles, short chrome labels.
    public static func headline(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .semibold)
    }
    /// Anything longer than a few words - messages, paths, tooltips.
    public static func body(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular)
    }
    /// Small secondary captions - "shot vs. current", filter chips, footnotes.
    public static func caption(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium)
    }
    /// Numeric readouts - slider values, histogram stats. Always monospaced digits so the
    /// value doesn't jitter horizontally as it changes.
    public static func numeric(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .semibold).monospacedDigit()
    }
}

private struct StudioFocusKey: EnvironmentKey {
    static let defaultValue = false
}
public extension EnvironmentValues {
    var studioFocusMode: Bool {
        get { self[StudioFocusKey.self] }
        set { self[StudioFocusKey.self] = newValue }
    }
}
