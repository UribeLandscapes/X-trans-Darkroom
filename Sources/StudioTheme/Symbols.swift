import SwiftUI

/// One case per former `RetroIcon`, each mapping to an SF Symbol name. `StudioOverlayChecks`
/// asserts every case resolves via `NSImage(systemSymbolName:accessibilityDescription:)`.
public enum StudioIcon: String, CaseIterable, Sendable {
    case folder, image, starFilled, starEmpty, flag, reject, crop, rotateLeft, rotateRight
    case flipH, flipV, undo, redo, export, `import`, settings, zoomIn, zoomOut, fit, oneToOne
    case histogram, curve, eyedropper, grain, check, chevron, camera, sparkles

    public var symbolName: String {
        switch self {
        case .folder: "folder"
        case .image: "photo"
        case .starFilled: "star.fill"
        case .starEmpty: "star"
        case .flag: "flag.fill"
        case .reject: "xmark.circle.fill"
        case .crop: "crop"
        case .rotateLeft: "rotate.left"
        case .rotateRight: "rotate.right"
        case .flipH: "arrow.left.and.right"
        case .flipV: "arrow.up.and.down"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .export: "square.and.arrow.up"
        case .import: "square.and.arrow.down"
        case .settings: "slider.horizontal.3"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .fit: "arrow.up.left.and.down.right.magnifyingglass"
        case .oneToOne: "1.magnifyingglass"
        case .histogram: "chart.bar.fill"
        case .curve: "chart.xyaxis.line"
        case .eyedropper: "eyedropper"
        case .grain: "circle.grid.3x3.fill"
        case .check: "checkmark"
        case .chevron: "chevron.right"
        case .sparkles: "sparkles"
        case .camera: "camera.aperture"
        }
    }
}

public extension Image {
    init(_ icon: StudioIcon) { self.init(systemName: icon.symbolName) }
}
