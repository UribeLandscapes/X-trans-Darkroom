import Foundation

public protocol RecipeStore: Sendable {
    func loadAll() async throws -> [Recipe]
    func upsert(_ recipe: Recipe) async throws
    func resolveExamplePhoto(_ filename: String) async throws -> URL?
}

/// Launch-time read only: load once into memory. No watchers, polling, live reload or
/// concurrent-write reconciliation. Explicit user saves are the only write path.
/// An actor serializes this store's own saves under Swift 6; it is not a sync engine.
public actor LocalRecipeStore: RecipeStore {
    public let spreadsheet: URL
    private var workbook: RecipeWorkbook?
    private var cached: [Recipe]?
    public enum WriteStage: Sendable { case staged, validated, backedUp }
    private let checkpoint: @Sendable (WriteStage, URL) throws -> Void

    /// The checkpoint permits deterministic disk-failure tests before the atomic swap.
    public init(spreadsheet: URL, checkpoint: @escaping @Sendable (WriteStage, URL) throws -> Void = { _, _ in }) {
        self.spreadsheet = spreadsheet; self.checkpoint = checkpoint
    }
    public func loadAll() throws -> [Recipe] {
        if let cached { return cached }
        let book = try RecipeWorkbook(Data(contentsOf: spreadsheet))
        let loaded = validatedRecipes(book)
        workbook = book; cached = loaded
        return loaded
    }
    public func resolveExamplePhoto(_ filename: String) throws -> URL? {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
              !filename.contains("\\"), !filename.contains("\0") else { throw RecipeStoreError.unsafeFilename }
        let folder = spreadsheet.deletingLastPathComponent().appendingPathComponent("examples", isDirectory: true)
        let url = folder.appendingPathComponent(filename)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath() else { throw RecipeStoreError.unsafeFilename }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue ? url : nil
    }
    private func validatedRecipes(_ book: RecipeWorkbook) -> [Recipe] {
        book.recipes().map { original in
            var recipe = original
            for field in Recipe.exampleFields where !recipe[field].isEmpty {
                do {
                    if try resolveExamplePhoto(recipe[field]) != nil { continue }
                    recipe.warnings.append(.init(row: recipe.row, field: field.rawValue, message: "Example photo is missing: \(recipe[field])"))
                } catch {
                    recipe.warnings.append(.init(row: recipe.row, field: field.rawValue, message: "Example must be a filename inside examples/"))
                }
            }
            return recipe
        }
    }
    public func upsert(_ recipe: Recipe) throws {
        _ = try loadAll()
        guard let workbook else { throw RecipeStoreError.missingSheet }
        try commit(workbook.updating(recipe), expected: [recipe])
    }

    /// Imports once into an existing blank workbook, using the normal staged/backup/swap path.
    public func importIntoBlank(_ recipes: [Recipe]) throws {
        let data = try Data(contentsOf: spreadsheet)
        let zip = try WorkbookZIP(data)
        let strings = SheetXML()
        if let shared = try zip.contents(RecipeWorkbook.stringsPath) { try strings.read(shared) }
        for entry in zip.entries where entry.name.hasPrefix("xl/worksheets/") && entry.name.hasSuffix(".xml") {
            let reader = SheetXML(); reader.sharedStrings = strings.strings
            try reader.read(zip.contents(entry.name)!)
            guard reader.rows.values.allSatisfy({ $0.values.allSatisfy(\.isEmpty) }) else { throw RecipeStoreError.invalidRecipe }
        }
        guard !recipes.isEmpty, Set(recipes.map(\.id)).count == recipes.count else { throw RecipeStoreError.invalidRecipe }
        let header = RecipeField.allCases.enumerated().map { index, field in
            "<c r=\"\(RecipeWorkbook.columnName(index + 1))1\" t=\"inlineStr\"><is><t>\(field.rawValue)</t></is></c>"
        }.joined()
        let sheet = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><dimension ref=\"A1\"/><sheetData><row r=\"1\">\(header)</row></sheetData></worksheet>"
        var result = try zip.replacing([RecipeWorkbook.sheetPath: Data(sheet.utf8)])
        for recipe in recipes { result = try RecipeWorkbook(result).updating(recipe) }
        try commit(result, expected: recipes)
    }

    private func commit(_ data: Data, expected: [Recipe]) throws {
        let fm = FileManager.default
        let parent = spreadsheet.deletingLastPathComponent()
        // Same-volume staging is necessary for an atomic replacement.
        let staged = parent.appendingPathComponent(".recipes-\(UUID().uuidString).xlsx")
        defer { try? fm.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        try checkpoint(.staged, staged)
        let reopened = try RecipeWorkbook(Data(contentsOf: staged))
        let saved = reopened.recipes()
        guard expected.allSatisfy({ recipe in
            saved.contains { row in row.id == recipe.id && recipe.fields.allSatisfy { row[$0.key] == $0.value } }
        }) else { throw RecipeStoreError.invalidRecipe }
        try checkpoint(.validated, staged)
        let backups = parent.appendingPathComponent("recipes-backup", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = Date()
        var backup = backups.appendingPathComponent(formatter.string(from: date) + ".xlsx")
        while fm.fileExists(atPath: backup.path) {
            date = date.addingTimeInterval(0.001); backup = backups.appendingPathComponent(formatter.string(from: date) + ".xlsx")
        }
        try fm.copyItem(at: spreadsheet, to: backup)
        try checkpoint(.backedUp, staged)
        _ = try fm.replaceItemAt(spreadsheet, withItemAt: staged)
        self.workbook = reopened; cached = validatedRecipes(reopened)
        // Retention happens only after the successful swap. A cleanup failure must not
        // report the already committed save as failed or encourage an accidental retry.
        let old = (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        let versions = old.filter { $0.pathExtension == "xlsx" && formatter.date(from: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in versions.dropFirst(20) { try? fm.removeItem(at: url) }
    }
}
