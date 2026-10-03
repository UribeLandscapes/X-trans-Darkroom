import SwiftUI
import RawDecode
import Catalog
import LibraryLogic
import StudioTheme

/// Library grid detail column. Folders and per-image metadata moved out to `SidebarView` and
/// `InspectorView` respectively as part of the iPadOS-style split-view shell; this view now
/// owns only the filter bar and the thumbnail grid.
struct LibraryView: View {
    @Environment(\.studioFocusMode) private var focused
    @ObservedObject var model: LibraryModel
    let open: (ImageRecord) -> Void
    var body: some View {
        VStack(spacing: 0) {
            // macOS 27 loops split-view constraint passes when chrome dictates the detail minimum.
            ViewThatFits(in: .horizontal) {
                filters(compact: false)
                filters(compact: true)
                Menu("Filters") {
                    filterChoices(compact: true)
                    Menu("Thumbnail size") {
                        Button("Small") { model.cellSize = 96 }
                        Button("Medium") { model.cellSize = 160 }
                        Button("Large") { model.cellSize = 320 }
                    }
                }.menuStyle(.borderlessButton)
            }
            .lineLimit(1).truncationMode(.tail)
            .padding(StudioMetrics.unit)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .studioSurface(fill: Studio.groupedPanel).saturation(focused ? 0 : 1).clipped()
            if model.isScanning {
                VStack(spacing: 8) {
                    ProgressView(value: Double(model.scanned), total: Double(max(1, model.total))).tint(Studio.accent)
                    Text("Scanning folder: \(model.scanned) / \(model.total)").font(StudioFont.numeric()).lineLimit(1).truncationMode(.tail)
                }.padding(8).frame(minWidth: 0, maxWidth: .infinity)
                    .background(Studio.groupedPanel).clipped()
            }
            ThumbnailGridView(model: model, open: open)
                .overlay { if model.rows.isEmpty && !model.isScanning { Text("Add a folder to browse, or adjust the filters.").font(StudioFont.body()).foregroundStyle(Studio.textSecondary).allowsHitTesting(false) } }
        }
    }
    private func filters(compact: Bool) -> some View {
        HStack(spacing: StudioMetrics.unit) {
            filterChoices(compact: compact)
            StudioSlider("Size", value: $model.cellSize, range: 96...320, neutral: 160,
                         showsValue: false, onLive: { _ in }, onCommit: { _ in }).frame(width: 128)
        }
    }
    @ViewBuilder private func filterChoices(compact: Bool) -> some View {
        choice("Sort", value: $model.sort, options: LibrarySort.allCases.map { ($0.rawValue, $0) }, compact: compact)
        choice("Type", value: $model.filter.fileType, options: (["All"] + SupportedFormats.all.sorted()).map { ($0.uppercased(), $0) }, compact: compact)
        choice("Rating", value: $model.filter.minimumRating, options: (0...5).map { ("\($0)+", $0) }, compact: compact)
        choice("Flag", value: $model.filter.flag, options: [("All", nil), ("Pick", 1), ("Reject", -1), ("Unflagged", 0)], compact: compact)
    }
    private func choice<T: Hashable>(_ label: String, value: Binding<T>, options: [(String, T)], compact: Bool) -> some View {
        Menu {
            ForEach(options, id: \.1) { option in Button(option.0) { value.wrappedValue = option.1 } }
        } label: {
            Text(compact ? label : "\(label): \(options.first { $0.1 == value.wrappedValue }?.0 ?? "All")")
                .font(StudioFont.caption()).foregroundStyle(Studio.textPrimary)
                .lineLimit(1).truncationMode(.tail).padding(8).studioSurface(fill: Studio.elevated)
        }.menuStyle(.borderlessButton)
    }
}
