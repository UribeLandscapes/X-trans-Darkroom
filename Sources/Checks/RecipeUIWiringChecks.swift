import Foundation
import Recipes
import RecipeUI
import LibraryLogic
import EditModel
import Profiles

private actor PendingRecipeStore: RecipeStore {
    private var continuation: CheckedContinuation<[Recipe], Error>?
    func loadAll() async throws -> [Recipe] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    var started: Bool { continuation != nil }
    func fail() { continuation?.resume(throwing: CocoaError(.fileReadNoPermission)); continuation = nil }
    func upsert(_ recipe: Recipe) {}
    func resolveExamplePhoto(_ filename: String) -> URL? { nil }
}

enum RecipeUIWiringChecks {
    @MainActor
    static func run(_ c: Checks) async {
        await c.suite("Recipe UI wiring") { c in
            let app = Checks.repoRoot().appendingPathComponent("Sources/App")
            let files = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            let imports = try files.filter {
                try String(contentsOf: $0, encoding: .utf8).split(separator: "\n")
                    .contains { $0.trimmingCharacters(in: .whitespaces) == "import Recipes" }
            }
            c.expect(!imports.isEmpty, "App imports Recipes; importing files=\(imports.count), scanned=\(files.count)")

            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let profileDir = dir.appendingPathComponent("profiles")
            try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try RecipeChecks.profileFixture().write(to: profileDir.appendingPathComponent("provia.dcp"))
            let profiles = ProfileLibrary(bundledDirectory: nil, userDirectory: profileDir)
            let recipe = Recipe(fields: [.recipeID: "ui", .name: "UI recipe", .filmSimulation: "Provia/Standard", .color: "2"])
            let context = RecipeApplication.Context(asShotTemperature: 5500)
            let applied = try RecipeApplication.apply(recipe, to: EditStack(), profiles: profiles, context: context)
            let unchanged = try RecipeApplication.isModified(recipe, stack: applied, profiles: profiles, context: context)
            let unchangedLabel = RecipeBrowserModel.attribution(for: recipe, modified: unchanged)
            c.expect(!unchanged && unchangedLabel == "based on UI recipe", "applied recipe is unmodified; modified=\(unchanged), saturation=\(applied.color.saturation)")
            var changed = applied
            changed.color.saturation += 1
            let modified = try RecipeApplication.isModified(recipe, stack: changed, profiles: profiles, context: context)
            let modifiedLabel = RecipeBrowserModel.attribution(for: recipe, modified: modified)
            c.expect(modified && modifiedLabel == "based on UI recipe - modified", "mapped hand edit is modified; modified=\(modified), delta=\(changed.color.saturation - applied.color.saturation)")
            var unrelated = applied
            unrelated.light.contrast = 12
            let unrelatedModified = try RecipeApplication.isModified(recipe, stack: unrelated, profiles: profiles, context: context)
            c.expect(!unrelatedModified, "unmapped contrast preserves attribution; modified=\(unrelatedModified), contrast=\(unrelated.light.contrast)")
            var history = EditHistory(EditStack())
            history.commit(applied)
            c.expect(history.undo() == EditStack() && !history.canUndo, "recipe application consumes one undo entry; remaining=\(history.canUndo ? 1 : 0)")
            c.expect(history.redo() == applied, "redo restores all recipe settings; recipeID=\(history.current.recipeID)")

            let suite = "recipe-ui-check-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = RecipeBrowserModel(defaults: defaults)
            let unreadable = dir.appendingPathComponent("offline.xlsx")
            await model.load(LocalRecipeStore(spreadsheet: unreadable))
            c.expect(!model.message.isEmpty && model.message.contains("Finder") && model.message.contains("Reload recipes") && !model.canSave,
                "unreadable workbook has actionable error; message chars=\(model.message.count), rows=\(model.recipes.count)")
            try Data().write(to: unreadable)
            await model.load(LocalRecipeStore(spreadsheet: unreadable))
            c.expect(model.message.contains("Could not read") && model.message.contains("downloaded") && !model.isLoading,
                "empty placeholder reports error; message chars=\(model.message.count), loading=\(model.isLoading)")

            let pending = PendingRecipeStore()
            let task = Task { await model.load(pending) }
            while !(await pending.started) { await Task.yield() }
            c.expect(model.isLoading && model.message.contains("Finder") && model.message.contains("Reload recipes"),
                "pending File Provider read shows advice before completion; loading=\(model.isLoading), message chars=\(model.message.count)")
            await pending.fail()
            await task.value
            c.expect(!model.isLoading && model.message.contains("Could not read"),
                "pending read failure remains visible; loading=\(model.isLoading), message chars=\(model.message.count)")

            // Exercise the same selection/persistence path used by the App; a corrupt workbook
            // still retains its bookmark so downloading it later does not require reselection.
            await model.choose(unreadable)
            let data = defaults.data(forKey: RecipeBrowserModel.bookmarkKey) ?? Data()
            c.expect(!data.isEmpty, "recipe selection persists security bookmark; bytes=\(data.count)")
            let decoded = try FolderBookmark.decode(data)
            c.expect(decoded.url.resolvingSymlinksInPath().path == unreadable.resolvingSymlinksInPath().path,
                "recipe bookmark round-trip; bytes=\(data.count), stale=\(decoded.stale)")
            let restored = RecipeBrowserModel(defaults: defaults)
            await restored.reload()
            c.expect(restored.hasBookmark && restored.message.contains("Could not read"),
                "launch restore reports unreadable bookmarked workbook; bookmark=\(restored.hasBookmark), message chars=\(restored.message.count)")
        }
    }
}
