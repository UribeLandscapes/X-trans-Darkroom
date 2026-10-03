import SwiftUI
import CoreImage
import EditModel
import ImagingCore
import ImageCanvas
import StudioTheme

struct CanvasArea: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var coordinator: RenderCoordinator
    @ObservedObject var viewer: ViewerState
    let focusMode: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let pixels = CGSize(width: geo.size.width*scale, height: geo.size.height*scale)
            ZStack(alignment: .topLeading) {
                Studio.surround(focused: focusMode)
                content(pixels: pixels)
                CanvasInfoOverlay(coordinator: coordinator, mode: viewer.infoMode)
                if viewer.cropEditing, let image = coordinator.displayImage {
                    CropOverlay(geometry: Binding(get: { editor.stack.geometry }, set: { editor.stack.geometry = $0 }),
                                imageSize: image.extent.size, onCommit: { editor.commit() })
                }
                if !coordinator.hasImage {
                    Text("Open an image to begin  (⌘O)").font(StudioFont.body(13))
                        .foregroundStyle(Studio.textSecondary).padding(16)
                }
            }
            .lineLimit(1).truncationMode(.tail)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading).clipped()
            .coordinateSpace(name: "comparison")
            .onChange(of: pixels, initial: true) { configure(pixels) }
            .onChange(of: coordinator.displayPixelSize) { configure(pixels) }
            .onChange(of: coordinator.beforePixelSize) { configure(pixels) }
            .onChange(of: scale) { configure(pixels) }
        }
        .overlay(alignment: .topTrailing) {
            if coordinator.isSettling {
                Text("Rendering").font(StudioFont.caption()).foregroundStyle(Studio.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(6).background(Studio.background).padding(8)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing).clipped()
            }
        }
        .padding(StudioMetrics.u(2))
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(Studio.surround(focused: focusMode)).clipped()
        .onAppear { viewer.onChange = { [weak editor] in editor?.viewerChanged() } }
    }

    private func configure(_ pixels: CGSize) {
        guard pixels.width > 0, pixels.height > 0 else { return }
        editor.canvasResized(to: Int(max(pixels.width, pixels.height)))
        viewer.configure(imageSize: coordinator.displayPixelSize, beforeSize: coordinator.beforePixelSize, canvasSize: pixels)
        editor.viewerChanged()
    }

    @ViewBuilder private func content(pixels: CGSize) -> some View {
        let mode = viewer.beforeAfterMode
        if mode.isPaired {
            let panes = mode.panes(in: pixels)
            pane(before: true, size: panes[0].size, label: true)
            pane(before: false, size: panes[1].size, label: true)
                .offset(x: panes[1].minX/scale, y: panes[1].minY/scale)
        } else if mode.isSplit {
            pane(before: false, size: pixels, label: false)
            pane(before: true, size: pixels, label: false)
                .allowsHitTesting(false)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: pixels.width/scale * (mode.isVertical ? 1 : viewer.dividerFraction),
                                      height: pixels.height/scale * (mode.isVertical ? viewer.dividerFraction : 1))
                }
            label("Before").padding(8).allowsHitTesting(false)
            label("After")
                .offset(x: mode.isVertical ? 8 : pixels.width/scale*viewer.dividerFraction+8,
                        y: mode.isVertical ? pixels.height/scale*viewer.dividerFraction+8 : 8)
                .allowsHitTesting(false)
            divider(size: CGSize(width: pixels.width/scale, height: pixels.height/scale))
        } else {
            pane(before: mode == .before, size: pixels, label: mode == .before)
        }
    }

    private func pane(before: Bool, size: CGSize, label showLabel: Bool) -> some View {
        let viewport = before ? viewer.viewport(for: coordinator.beforePixelSize) : viewer.viewport
        return ImageCanvasView(image: before ? coordinator.beforeImage : coordinator.displayImage,
                               viewport: viewport, surround: Studio.surroundLevel(focused: focusMode),
                               inputEnabled: !viewer.cropEditing, showClipping: !before && viewer.showClipping,
                               pickerActive: !before && viewer.wbPickerActive,
                               onPick: { editor.pickWhiteBalance(at: $0) }) { input in viewer.input(input, using: viewport) }
            .frame(width: size.width/scale, height: size.height/scale)
            .overlay(alignment: .topLeading) {
                if showLabel { label(before ? "Before" : "After").padding(8).allowsHitTesting(false) }
            }
    }
    private func label(_ text: String) -> some View {
        Text(text).font(StudioFont.caption()).foregroundStyle(Studio.textSecondary)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 3).background(Studio.background)
    }
    private func divider(size: CGSize) -> some View {
        let vertical = viewer.beforeAfterMode.isVertical
        return ZStack {
            Rectangle().fill(Studio.textSecondary)
                .frame(width: vertical ? size.width : 1/scale, height: vertical ? 1/scale : size.height)
            RoundedRectangle(cornerRadius: 2).fill(Studio.groupedPanel)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Studio.textSecondary, lineWidth: 1/scale))
                .frame(width: vertical ? 28 : 8, height: vertical ? 8 : 28)
        }
        .frame(width: vertical ? size.width : 16, height: vertical ? 16 : size.height)
        .contentShape(Rectangle())
        .position(x: vertical ? size.width/2 : size.width*viewer.dividerFraction,
                  y: vertical ? size.height*viewer.dividerFraction : size.height/2)
        .gesture(DragGesture(coordinateSpace: .named("comparison"))
            .onChanged { event in
                viewer.dividerFraction = BeforeAfterMode.divider(vertical ? event.location.y/size.height : event.location.x/size.width)
            })
        .accessibilityLabel("Before and after divider")
    }
}
