import Foundation
import CoreGraphics

public enum ZoomMode: Equatable, Sendable {
    case fit, fill, custom(Double)
}

/// View points are backing pixels, top-left origin; image points are full-resolution
/// pixels, bottom-left origin. Center is normalized so it survives proxy swaps.
public struct CanvasViewport: Equatable, Sendable {
    public private(set) var zoom: Double
    public private(set) var center: CGPoint
    public let imageSize: CGSize
    public let viewSizePx: CGSize

    public init(imageSize: CGSize, viewSizePx: CGSize, zoom: Double, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.imageSize = CGSize(width: max(1, imageSize.width), height: max(1, imageSize.height))
        self.viewSizePx = CGSize(width: max(1, viewSizePx.width), height: max(1, viewSizePx.height))
        self.zoom = min(16, max(Self.minimumZoom(imageSize: self.imageSize, viewSizePx: self.viewSizePx), zoom.isFinite ? zoom : 1))
        self.center = center
        clampCenter()
    }

    public static func fitZoom(imageSize: CGSize, viewSizePx: CGSize) -> Double {
        min(viewSizePx.width / max(1, imageSize.width), viewSizePx.height / max(1, imageSize.height))
    }
    public static func fillZoom(imageSize: CGSize, viewSizePx: CGSize) -> Double {
        max(viewSizePx.width / max(1, imageSize.width), viewSizePx.height / max(1, imageSize.height))
    }
    public static func minimumZoom(imageSize: CGSize, viewSizePx: CGSize) -> Double {
        max(Double.leastNormalMagnitude, min(0.0625, fitZoom(imageSize: imageSize, viewSizePx: viewSizePx)))
    }
    public var minimumZoom: Double { Self.minimumZoom(imageSize: imageSize, viewSizePx: viewSizePx) }
    public var pannable: Bool { imageSize.width * zoom > viewSizePx.width || imageSize.height * zoom > viewSizePx.height }
    public static func needsFullFrame(displayedScale: Double, proxyRatio: Double) -> Bool { displayedScale > proxyRatio }

    private mutating func clampCenter() {
        func axis(_ value: Double, _ image: Double, _ view: Double) -> Double {
            let half = view / (2 * image * zoom)
            return half >= 0.5 ? 0.5 : min(1-half, max(half, value.isFinite ? value : 0.5))
        }
        center = CGPoint(x: axis(center.x, imageSize.width, viewSizePx.width),
                         y: axis(center.y, imageSize.height, viewSizePx.height))
    }
    public func viewPoint(imagePoint p: CGPoint) -> CGPoint {
        CGPoint(x: viewSizePx.width/2 + (p.x-center.x*imageSize.width)*zoom,
                y: viewSizePx.height/2 - (p.y-center.y*imageSize.height)*zoom)
    }
    public func imagePoint(viewPoint p: CGPoint) -> CGPoint {
        CGPoint(x: center.x*imageSize.width + (p.x-viewSizePx.width/2)/zoom,
                y: center.y*imageSize.height - (p.y-viewSizePx.height/2)/zoom)
    }
    public mutating func zoom(by factor: Double, anchoredAt p: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = imagePoint(viewPoint: p)
        zoom = min(16, max(minimumZoom, zoom*factor))
        center = CGPoint(x: (anchor.x-(p.x-viewSizePx.width/2)/zoom)/imageSize.width,
                         y: (anchor.y+(p.y-viewSizePx.height/2)/zoom)/imageSize.height)
        // At an image edge, avoiding empty space takes precedence over anchoring.
        clampCenter()
    }
    public mutating func pan(byViewDelta delta: CGSize) {
        center.x -= delta.width / (zoom*imageSize.width)
        center.y += delta.height / (zoom*imageSize.height)
        clampCenter()
    }
    public var visibleImageRect: CGRect {
        let size = CGSize(width: viewSizePx.width/zoom, height: viewSizePx.height/zoom)
        return CGRect(x: center.x*imageSize.width-size.width/2, y: center.y*imageSize.height-size.height/2,
                      width: size.width, height: size.height).intersection(CGRect(origin: .zero, size: imageSize))
    }
    public func renderedScale(renderedWidth: Double) -> Double { zoom / (renderedWidth / imageSize.width) }
    public static func sliderFraction(zoom: Double, minimum: Double) -> Double {
        log(min(16, max(minimum, zoom))/minimum) / log(16/minimum)
    }
    public static func sliderZoom(fraction: Double, minimum: Double) -> Double {
        minimum * pow(16/minimum, min(1, max(0, fraction)))
    }
}

public enum BeforeAfterMode: String, CaseIterable, Sendable {
    case off = "After only", before = "Before only"
    case sideBySide = "Left / Right", topBottom = "Top / Bottom"
    case splitLeftRight = "Split Left / Right", splitTopBottom = "Split Top / Bottom"
    public var isPaired: Bool { self == .sideBySide || self == .topBottom }
    public var isSplit: Bool { self == .splitLeftRight || self == .splitTopBottom }
    public var isVertical: Bool { self == .topBottom || self == .splitTopBottom }
    public static func divider(_ fraction: Double) -> Double { min(0.95, max(0.05, fraction)) }
    /// Top-left view coordinates; the gap is one backing pixel.
    public func panes(in size: CGSize) -> [CGRect] {
        if self == .sideBySide {
            let w = max(0, (size.width-1)/2)
            return [CGRect(x: 0, y: 0, width: w, height: size.height), CGRect(x: w+1, y: 0, width: w, height: size.height)]
        }
        if self == .topBottom {
            let h = max(0, (size.height-1)/2)
            return [CGRect(x: 0, y: 0, width: size.width, height: h), CGRect(x: 0, y: h+1, width: size.width, height: h)]
        }
        return [CGRect(origin: .zero, size: size)]
    }
}
