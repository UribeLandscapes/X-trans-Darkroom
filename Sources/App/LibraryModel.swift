import SwiftUI
import AppKit
import Catalog
import LibraryLogic
import EditModel

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var roots: [URL] = []
    @Published private(set) var rows: [ImageRecord] = []
    @Published var selectedPaths: Set<String> = []
    @Published var selection: String?
    @Published var sort: LibrarySort = .captureDate { didSet { apply() } }
    @Published var filter = LibraryFilter() { didSet { apply() } }
    @Published var cellSize = 160.0
    @Published private(set) var scanned = 0
    @Published private(set) var total = 0
    @Published private(set) var isScanning = false
    @Published var error: String?
    private(set) var cache: ThumbnailCache?
    private var catalog: Catalog?
    private var leases: [FolderAccess] = []
    private var bookmarks: [Data] = []
    private var unresolvedBookmarks: [Data] = []
    private var allRows: [ImageRecord] = []
    private var dates: [String: Date] = [:]
    private var scanTask: Task<Void, Never>?
    private var generation = 0
    private let defaults: UserDefaults
    private let bookmarkKey = "library.rootBookmarks"

    var selected: ImageRecord? { rows.first { $0.path == selection } }
    func access(for path: String) -> FolderAccess? {
        leases.first { path.hasPrefix($0.url.path + "/") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("XTransDarkroom")
            catalog = try Catalog(url: base.appendingPathComponent("catalog.sqlite"))
            cache = try ThumbnailCache(root: base.appendingPathComponent("thumbnails"), byteCeiling: 2_000_000_000)
            for data in defaults.array(forKey: bookmarkKey) as? [Data] ?? [] {
                do {
                    let resolved = try FolderBookmark.decode(data)
                    let lease = FolderAccess(resolved.url)
                    bookmarks.append(resolved.stale ? try FolderBookmark.encode(resolved.url) : data)
                    leases.append(lease)
                } catch { unresolvedBookmarks.append(data); self.error = "Folder access: \(error.localizedDescription)" }
            }
            roots = leases.map(\.url)
            // Keep unresolved bookmarks so a temporarily offline drive can return.
            persistBookmarks()
            scan()
        } catch { self.error = error.localizedDescription }
    }

    private func persistBookmarks() {
        defaults.set(bookmarks + unresolvedBookmarks, forKey: bookmarkKey)
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls where !roots.contains(url) {
                let lease = FolderAccess(url)
                let data = try FolderBookmark.encode(url)
                leases.append(lease); bookmarks.append(data); roots.append(url)
            }
            persistBookmarks()
            scan()
        } catch { self.error = error.localizedDescription }
    }

    func removeRoot(_ url: URL) {
        guard let index = roots.firstIndex(of: url) else { return }
        roots.remove(at: index); leases.remove(at: index); bookmarks.remove(at: index)
        persistBookmarks()
        allRows.removeAll { row in !roots.contains { row.path.hasPrefix($0.path + "/") } }
        apply()
        scan()
    }

    func scan() {
        scanTask?.cancel()
        generation += 1
        let token = generation
        guard let catalog else { return }
        let active = leases
        isScanning = true; scanned = 0; total = 0
        scanTask = Task { [weak self] in
            do {
                for lease in active {
                    try Task.checkCancellation()
                    let scan = Scanner(catalog: catalog).scan(root: lease.url)
                    try await withTaskCancellationHandler {
                        for await progress in scan.progress {
                            guard let self, self.generation == token else { continue }
                            self.scanned = progress.scanned; self.total = progress.total
                        }
                        _ = try await scan.result.value
                    } onCancel: { scan.cancel() }
                }
                try Task.checkCancellation()
                let fetched = try await catalog.fetch()
                let facts = await Task.detached {
                    var dates: [String: Date] = [:]
                    var rows = fetched.filter { row in active.contains { row.path.hasPrefix($0.url.path + "/") } }
                    for i in rows.indices {
                        let url = URL(fileURLWithPath: rows[i].path)
                        dates[rows[i].path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        if let stack = try? Sidecar.load(forImageAt: url), stack.fingerprint == rows[i].fingerprint, !stack.isNeutral { rows[i].editHash = stack.settingsHash }
                    }
                    return (rows, dates)
                }.value
                guard let self, self.generation == token else { return }
                self.allRows = facts.0; self.dates = facts.1; self.apply()
            } catch is CancellationError {} catch {
                if let self, self.generation == token { self.error = error.localizedDescription }
            }
            if let self, self.generation == token { self.isScanning = false }
        }
    }

    private func apply() {
        rows = allRows.filter(filter.matches).sorted { sort.precedes($0, $1, fileDates: dates) }
        selectedPaths.formIntersection(Set(rows.map(\.path)))
        if !rows.contains(where: { $0.path == selection }) { selection = nil }
    }

    func record(for path: String) -> ImageRecord? { allRows.first { $0.path == path } }
    private var annotationTask: Task<Void, Never>?
    func annotate(_ key: LibraryKey, path: String? = nil) {
        guard let path = path ?? selection, let index = allRows.firstIndex(where: { $0.path == path }),
              let id = allRows[index].id, let catalog else { return }
        switch key {
        case .rating(let value): allRows[index].rating = value
        case .flag(let value): allRows[index].flag = value
        case .open: return
        }
        apply()
        let previous = annotationTask
        annotationTask = Task {
            await previous?.value
            do {
                switch key {
                case .rating(let value): try await catalog.setRating(value, for: id)
                case .flag(let value): try await catalog.setFlag(value, for: id)
                case .open: break
                }
            } catch { self.error = error.localizedDescription; self.scan() }
        }
    }
}
