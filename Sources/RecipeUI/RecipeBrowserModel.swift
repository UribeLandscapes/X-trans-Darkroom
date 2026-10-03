import Foundation
import Combine
import Recipes
import LibraryLogic
import Catalog

/// Shared with Checks so failure presentation is exercised without launching a window.
@MainActor
public final class RecipeBrowserModel: ObservableObject {
    public static let bookmarkKey = "recipes.spreadsheetBookmark"
    public static let downloadAdvice = "Recipe file may not be downloaded yet — open it in Finder once, then Reload recipes. If the drive is offline, reconnect it or choose the spreadsheet again."
    @Published public private(set) var recipes: [Recipe] = []
    @Published public private(set) var message = "Choose a recipe spreadsheet to begin."
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var spreadsheet: URL?
    private let defaults: UserDefaults
    private var store: (any RecipeStore)?
    private var access: FolderAccess?
    private var thumbnailCache: ThumbnailCache?
    private var generation = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func attribution(for recipe: Recipe, modified: Bool) -> String {
        "based on " + recipe.name + (modified ? " - modified" : "")
    }

    public var hasBookmark: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }
    public var canSave: Bool { store != nil && !isLoading && !isSaving }

    public func choose(_ url: URL) async {
        guard !isSaving else { return }
        do {
            let lease = FolderAccess(url)
            defaults.set(try FolderBookmark.encode(url), forKey: Self.bookmarkKey)
            await read(url, access: lease)
        } catch { message = "Could not remember recipe spreadsheet: \(error.localizedDescription). Choose it again." }
    }

    public func reload() async {
        guard !isSaving, let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        do {
            let resolved = try FolderBookmark.decode(data)
            let lease = FolderAccess(resolved.url)
            if resolved.stale { defaults.set(try FolderBookmark.encode(resolved.url), forKey: Self.bookmarkKey) }
            await read(resolved.url, access: lease)
        } catch {
            generation += 1
            isLoading = false; store = nil
            message = "Could not access recipe spreadsheet: \(error.localizedDescription). " + Self.downloadAdvice
        }
    }

    private func read(_ url: URL, access: FolderAccess) async {
        spreadsheet = url
        self.access = access
        // A fresh store is required for explicit reload because LocalRecipeStore caches its snapshot.
        await load(LocalRecipeStore(spreadsheet: url), access: access)
    }

    public func load(_ candidate: any RecipeStore, access lease: FolderAccess? = nil) async {
        defer { withExtendedLifetime(lease) {} }
        generation += 1
        let token = generation
        isLoading = true; store = nil
        // Advice is visible immediately: a File Provider can block a read for an unbounded time.
        message = "Loading recipe spreadsheet. " + Self.downloadAdvice
        do {
            let loaded = try await candidate.loadAll()
            guard token == generation else { return }
            recipes = loaded; store = candidate
            message = loaded.isEmpty ? "The spreadsheet contains no recipe rows. Add a recipe or choose another .xlsx file." : "Loaded \(loaded.count) recipes."
        } catch {
            guard token == generation else { return }
            message = "Could not read recipe spreadsheet: \(error.localizedDescription). " + Self.downloadAdvice
        }
        // Retain security scope until the read finishes, including superseded reads.
        if token == generation { isLoading = false }
    }

    public func save(_ recipe: Recipe) async -> Bool {
        guard canSave, let store else { return false }
        let warnings = recipe.validationWarnings()
        guard warnings.isEmpty else {
            message = warnings.map { "\($0.field): \($0.message)" }.joined(separator: "\n")
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.upsert(recipe)
            recipes = try await store.loadAll()
            message = "Saved \(recipe.name). A backup of the previous workbook was kept."
            return true
        } catch {
            message = "Could not save recipe: \(error.localizedDescription). Check that the spreadsheet and its folder are downloaded and writable, then retry."
            return false
        }
    }

    public func thumbnail(_ filename: String) async throws -> URL {
        guard let store else { throw CocoaError(.fileReadNoSuchFile) }
        if thumbnailCache == nil { thumbnailCache = try ThumbnailCache() }
        guard let cache = thumbnailCache else { throw CocoaError(.fileReadUnknown) }
        let lease = access
        defer { withExtendedLifetime(lease) {} }
        guard let url = try await store.resolveExamplePhoto(filename) else { throw CocoaError(.fileReadNoSuchFile) }
        let fingerprint = try await Task.detached {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(url.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.value
        return try await cache.thumbnail(for: url, fingerprint: fingerprint, size: .grid)
    }
}
