import Foundation

/// Shared coordinate math has no UI dependencies. Normalized coordinates follow Core
/// Image's bottom-left origin; view coordinates follow SwiftUI's top-left origin.
public struct CanvasGeometry: Sendable {
    public let imageRect: CGRect
    public init(imageSize: CGSize, viewSize: CGSize, zoom: CGFloat = 1) {
        let scale = min(viewSize.width / max(1, imageSize.width), viewSize.height / max(1, imageSize.height)) * zoom
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        imageRect = CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2, width: size.width, height: size.height)
    }
    public func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageRect.minX) / imageRect.width, y: 1 - (p.y - imageRect.minY) / imageRect.height)
    }
    public func view(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * imageRect.width, y: imageRect.minY + (1 - p.y) * imageRect.height)
    }
    public func viewRect(_ r: CGRect) -> CGRect {
        CGRect(origin: view(CGPoint(x: r.minX, y: r.maxY)), size: CGSize(width: r.width * imageRect.width, height: r.height * imageRect.height))
    }
}

public enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    public func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.maxY)
        case .top: CGPoint(x: r.midX, y: r.maxY)
        case .topRight: CGPoint(x: r.maxX, y: r.maxY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottom: CGPoint(x: r.midX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.minY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }
    public static func hit(_ p: CGPoint, rect: CGRect, mapping: CanvasGeometry, radius: CGFloat = 12) -> Self? {
        allCases.min { a, b in
            let x = mapping.view(a.point(in: rect)), y = mapping.view(b.point(in: rect))
            return hypot(p.x-x.x, p.y-x.y) < hypot(p.x-y.x, p.y-y.y)
        }.flatMap { h in
            let q = mapping.view(h.point(in: rect))
            return hypot(p.x-q.x, p.y-q.y) <= radius ? h : nil
        }
    }
    public func dragging(_ rect: CGRect, to p: CGPoint) -> CGRect {
        let epsilon: CGFloat = 0.001
        var x0 = max(0, min(1-epsilon, rect.minX)), y0 = max(0, min(1-epsilon, rect.minY))
        var x1 = max(x0+epsilon, min(1, rect.maxX)), y1 = max(y0+epsilon, min(1, rect.maxY))
        if [.topLeft, .left, .bottomLeft].contains(self) { x0 = max(0, min(x1-epsilon, p.x)) }
        if [.topRight, .right, .bottomRight].contains(self) { x1 = min(1, max(x0+epsilon, p.x)) }
        if [.bottomLeft, .bottom, .bottomRight].contains(self) { y0 = max(0, min(y1-epsilon, p.y)) }
        if [.topLeft, .top, .topRight].contains(self) { y1 = min(1, max(y0+epsilon, p.y)) }
        return CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0)
    }
}
