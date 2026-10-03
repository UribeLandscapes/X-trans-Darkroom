import SwiftUI
import ImagingCore
import EditModel

/// Chrome stays in App. Only normalized geometry reaches the edit stack; no overlay
/// pixels can enter the colour-managed image or an export.
struct CropOverlay: View {
    @Binding var geometry: GeometryAdjustments
    let imageSize: CGSize
    let onCommit: () -> Void
    @State private var active: CropHandle?
    @State private var initial: CGRect?

    private var rect: CGRect {
        CGRect(x: geometry.cropX, y: geometry.cropY, width: geometry.cropWidth, height: geometry.cropHeight)
    }
    var body: some View {
        GeometryReader { proxy in
            let mapping = CanvasGeometry(imageSize: imageSize, viewSize: proxy.size)
            let box = mapping.viewRect(rect)
            Canvas { context, _ in
                var grid = Path()
                grid.addRect(box)
                for i in 1...2 {
                    let f = CGFloat(i)/3
                    grid.move(to: CGPoint(x: box.minX+box.width*f, y: box.minY))
                    grid.addLine(to: CGPoint(x: box.minX+box.width*f, y: box.maxY))
                    grid.move(to: CGPoint(x: box.minX, y: box.minY+box.height*f))
                    grid.addLine(to: CGPoint(x: box.maxX, y: box.minY+box.height*f))
                }
                // Dual neutral strokes remain visible over both dark and bright images.
                context.stroke(grid, with: .color(.black), lineWidth: 2)
                context.stroke(grid, with: .color(.white), lineWidth: 1)
                for handle in CropHandle.allCases {
                    let p = mapping.view(handle.point(in: rect))
                    let r = CGRect(x: p.x-5, y: p.y-5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: r), with: .color(.white))
                    context.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if initial == nil {
                        active = CropHandle.hit(value.startLocation, rect: rect, mapping: mapping)
                        initial = rect
                    }
                    guard let active, let initial else { return }
                    let r = active.dragging(initial, to: mapping.normalized(value.location))
                    geometry.cropX = r.minX; geometry.cropY = r.minY
                    geometry.cropWidth = r.width; geometry.cropHeight = r.height
                }
                .onEnded { _ in
                    if active != nil { onCommit() }
                    active = nil; initial = nil
                })
            .accessibilityLabel("Crop handles")
            .accessibilityHint("Drag a corner or edge to crop. Aspect presets are available in Geometry.")
        }
    }
}
