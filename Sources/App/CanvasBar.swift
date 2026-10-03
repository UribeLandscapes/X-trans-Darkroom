import SwiftUI
import ImagingCore
import StudioTheme

struct CanvasBar: View {
    @ObservedObject var viewer: ViewerState
    @State private var draft = ""
    @FocusState private var editing: Bool
    private var fraction: Double {
        CanvasViewport.sliderFraction(zoom: viewer.viewport.zoom, minimum: viewer.viewport.minimumZoom)
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(detail: 2)
            controls(detail: 1)
            controls(detail: 0)
        }
        .lineLimit(1).truncationMode(.tail)
        .disabled(viewer.cropEditing)
        .foregroundStyle(Studio.textSecondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
        // Keep the split child's minimum independent of the selected bar variant.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .background(Studio.groupedPanel).clipped()
    }
    private func controls(detail: Int) -> some View {
        HStack(spacing: 8) {
            modeButton("Fit", selected: viewer.zoomMode == .fit, action: viewer.zoomToFit)
            modeButton("Fill", selected: viewer.zoomMode == .fill, action: viewer.zoomToFill)
            if detail > 0 {
                StudioSlider("Zoom", value: Binding(get: { fraction }, set: { setFraction($0) }),
                             range: 0...1, showsValue: false, onLive: { _ in }, onCommit: { _ in })
                    .frame(width: 190)
            }
            if detail > 1 {
                TextField("Zoom", text: $draft).textFieldStyle(.plain)
                    .font(StudioFont.numeric(11)).foregroundStyle(Studio.textSecondary)
                    .multilineTextAlignment(.trailing).frame(width: 52).focused($editing)
                    .onSubmit { finish() }
                    .onChange(of: editing) { if !editing { finish() } }
                    .onChange(of: viewer.percent, initial: true) { if !editing { draft = viewer.percent } }
                modeButton("1:1", selected: viewer.zoomMode == .custom(1), action: viewer.zoom1to1)
            }
            Button(action: viewer.cycleBeforeAfter) {
                Image(systemName: "rectangle.split.2x1")
            }.buttonStyle(.plain).accessibilityLabel("Cycle before and after")
            if detail > 0 {
                Menu {
                    ForEach(BeforeAfterMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { viewer.setBeforeAfter(mode) }
                    }
                } label: { Text(viewer.beforeAfterMode.rawValue).font(StudioFont.caption()) }
                .menuStyle(.borderlessButton)
            }
        }
    }
    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(StudioFont.caption()).padding(.horizontal, 7).padding(.vertical, 4)
                .background(selected ? Studio.neutralSelection : Studio.groupedPanel)
        }.buttonStyle(.plain)
    }
    private func setFraction(_ value: Double) {
        viewer.setZoom(CanvasViewport.sliderZoom(fraction: value, minimum: viewer.viewport.minimumZoom))
    }
    private func finish() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
        if text == "1:1" { viewer.zoom1to1() }
        else if let percent = Double(text), percent.isFinite { viewer.setZoom(max(0.001, percent/100)) }
        draft = viewer.percent
        editing = false
    }
}
