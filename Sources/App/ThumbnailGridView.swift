import SwiftUI
import AppKit
import Catalog
import LibraryLogic
import StudioTheme

struct ThumbnailGridView: NSViewRepresentable {
    @ObservedObject var model: LibraryModel
    let open: (ImageRecord) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.backgroundColor = NSColor(Studio.canvasSurround)
        let grid = LibraryCollectionView()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = StudioMetrics.unit
        layout.minimumLineSpacing = StudioMetrics.unit
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        grid.collectionViewLayout = layout
        grid.backgroundColors = [NSColor(Studio.canvasSurround)]
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.register(ThumbnailItem.self, forItemWithIdentifier: .init("thumbnail"))
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.prefetchDataSource = context.coordinator
        grid.keyHandler = { [weak coordinator = context.coordinator] event in coordinator?.key(event) ?? false }
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        grid.addGestureRecognizer(doubleClick)
        scroll.documentView = grid
        context.coordinator.grid = grid
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let grid = coordinator.grid, let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let size = NSSize(width: model.cellSize, height: model.cellSize + 40)
        if layout.itemSize != size { layout.itemSize = size; layout.invalidateLayout() }
        if coordinator.rows != model.rows {
            coordinator.cancelPrefetch()
            coordinator.rows = model.rows
            grid.reloadData()
        }
        let paths = Set(model.rows.enumerated().filter { model.selectedPaths.contains($0.element.path) }.map { IndexPath(item: $0.offset, section: 0) })
        if grid.selectionIndexPaths != paths {
            grid.selectionIndexPaths = paths
            if !paths.isEmpty { grid.scrollToItems(at: paths, scrollPosition: .nearestVerticalEdge) }
        }
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPrefetch()
        coordinator.grid?.visibleItems().forEach { ($0 as? ThumbnailItem)?.cancel() }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        var parent: ThumbnailGridView
        var rows: [ImageRecord] = []
        weak var grid: LibraryCollectionView?
        var prefetch: [IndexPath: Task<Void, Never>] = [:]
        init(_ parent: ThumbnailGridView) { self.parent = parent }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("thumbnail"), for: indexPath) as! ThumbnailItem
            let row = rows[indexPath.item]
            item.configure(row, cache: parent.model.cache, lease: parent.model.access(for: row.path))
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelection(collectionView)
        }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelection(collectionView)
        }
        private func syncSelection(_ collectionView: NSCollectionView) {
            let paths = collectionView.selectionIndexPaths.filter { rows.indices.contains($0.item) }
            parent.model.selectedPaths = Set(paths.map { rows[$0.item].path })
            parent.model.selection = paths.sorted().first.map { rows[$0.item].path }
        }
        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? ThumbnailItem)?.cancel()
        }
        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let cache = parent.model.cache else { return }
            for path in indexPaths where rows.indices.contains(path.item) && prefetch[path] == nil {
                let row = rows[path.item]
                let lease = parent.model.access(for: row.path)
                prefetch[path] = Task {
                    defer { withExtendedLifetime(lease) {} }
                    guard !Task.isCancelled else { return }
                    _ = try? await ThumbnailRendering.thumbnail(row, cache: cache)
                }
            }
        }
        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            for path in indexPaths { prefetch.removeValue(forKey: path)?.cancel() }
        }
        func cancelPrefetch() { prefetch.values.forEach { $0.cancel() }; prefetch.removeAll() }
        @objc func doubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let grid, let index = grid.indexPathForItem(at: gesture.location(in: grid))?.item, rows.indices.contains(index) else { return }
            parent.model.selection = rows[index].path
            parent.open(rows[index])
        }
        func key(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            let columns = max(1, Int(((grid?.bounds.width ?? 0) - 16 + 8) / (parent.model.cellSize + 8)))
            let delta: Int
            switch event.keyCode {
            case 125: delta = columns
            case 126: delta = -columns
            default: return false // Shared window monitor owns horizontal navigation and annotations.
            }
            if let index = LibraryKey.move(index: rows.firstIndex { $0.path == parent.model.selection }, by: delta, count: rows.count) {
                parent.model.selection = rows[index].path
                parent.model.selectedPaths = [rows[index].path]
                let paths: Set<IndexPath> = [IndexPath(item: index, section: 0)]
                grid?.selectionIndexPaths = paths
                grid?.scrollToItems(at: paths, scrollPosition: .nearestVerticalEdge)
            }
            return true
        }
    }
}

final class LibraryCollectionView: NSCollectionView {
    var keyHandler: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { window.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class ThumbnailItem: NSCollectionViewItem {
    private var load: Task<Void, Never>?
    private var identity: UUID?
    private let photo = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let stars = StudioStars()
    private let badge = NSTextField(labelWithString: "EDIT")
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(Studio.canvasSurround).cgColor
        view.layer?.cornerRadius = StudioMetrics.cornerControl
        view.layer?.cornerCurve = .continuous
        photo.imageScaling = .scaleProportionallyUpOrDown
        photo.wantsLayer = true
        photo.layer?.cornerRadius = StudioMetrics.cornerControl
        photo.layer?.cornerCurve = .continuous
        photo.layer?.masksToBounds = true
        caption.font = StudioFont.appKitBody(10)
        caption.textColor = NSColor(Studio.textPrimary)
        caption.lineBreakMode = .byTruncatingMiddle
        badge.font = StudioFont.appKitLabel(9)
        badge.textColor = NSColor(Studio.textPrimary)
        badge.backgroundColor = NSColor(Studio.accent).withAlphaComponent(0.85)
        badge.drawsBackground = true
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.cornerCurve = .continuous
        badge.layer?.masksToBounds = true
        for child in [photo, caption, stars, badge] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            photo.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), photo.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            photo.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), photo.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), caption.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            stars.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), stars.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8), stars.widthAnchor.constraint(equalToConstant: 80), stars.heightAnchor.constraint(equalToConstant: 14),
            // Inset so the badge sits inside the photo's corner, not floating above it.
            badge.topAnchor.constraint(equalTo: photo.topAnchor, constant: 4), badge.trailingAnchor.constraint(equalTo: photo.trailingAnchor, constant: -4),
            badge.widthAnchor.constraint(equalToConstant: 32), badge.heightAnchor.constraint(equalToConstant: 14)
        ])
    }
    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor(Studio.accent).cgColor
        }
    }
    func cancel() { load?.cancel(); load = nil; identity = nil }
    override func prepareForReuse() { super.prepareForReuse(); cancel(); photo.image = nil }
    func configure(_ row: ImageRecord, cache: ThumbnailCache?, lease: FolderAccess?) {
        cancel(); photo.image = nil; caption.toolTip = nil
        caption.stringValue = row.filename
        stars.rating = row.rating
        badge.isHidden = row.editHash.isEmpty
        view.setAccessibilityLabel("\(row.filename), \(row.rating) stars, flag \(row.flag)")
        let token = UUID(); identity = token
        guard let cache else { return }
        load = Task { [weak self] in
            defer { withExtendedLifetime(lease) {} }
            do {
                let url = try await ThumbnailRendering.thumbnail(row, cache: cache)
                try Task.checkCancellation()
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                guard !Task.isCancelled, let self, self.identity == token else { return }
                self.photo.image = NSImage(data: data)
            } catch {
                guard !Task.isCancelled, self?.identity == token else { return }
                self?.caption.toolTip = error.localizedDescription
            }
        }
    }
}

/// Star rating drawn with SF Symbols, tinted with the accent colour.
final class StudioStars: NSView {
    var rating = 0 { didSet { needsDisplay = true } }
    private static func symbol(_ icon: StudioIcon, tint: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [tint]))
        return NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
    override func draw(_ dirtyRect: NSRect) {
        let tint = NSColor(Studio.accent)
        let filled = Self.symbol(.starFilled, tint: tint)
        let empty = Self.symbol(.starEmpty, tint: NSColor(Studio.textSecondary))
        for star in 0..<5 {
            let rect = NSRect(x: CGFloat(star) * 16, y: 0, width: 14, height: 14)
            (star < rating ? filled : empty)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}
