import Foundation
import Catalog
import LibraryLogic
import RawDecode
import EditModel
import Recipes
import RecipeUI

extension EditorModel {
    var recipeSelection: RecipeSelection {
        RecipeSelection(library?.rows.filter { selectedLibraryPaths.contains($0.path) } ?? [])
    }
    var canApplyRecipe: Bool { libraryMode ? !recipeSelection.eligible.isEmpty : canUseCamera }

    func applyLibraryRecipe(_ recipe: Recipe) throws {
        let selection = recipeSelection
        var applied = 0
        defer { library?.scan() }
        do {
            for row in selection.eligible {
                let url = URL(fileURLWithPath: row.path)
                let meta = CoreImageRawDecoder.readMetadata(url)
                // Recheck the source before writing; a catalog row can outlive a replaced file.
                guard meta.cameraSource.isFujifilmRAF else { continue }
                let frame = try CoreImageRawDecoder().decode(url, scale: .atLeast(pixels: 512))
                var original = try Sidecar.load(forImageAt: url) ?? .freshOpenDefault(for: url)
                if coordinator.sourceURL == url { original = self.stack }
                var panel = CameraPanelState(asShot: frame.asShotSettings, saved: original.cameraSettings)
                try panel.apply(recipe)
                var stack = try panel.resolved(on: original, profiles: coordinator.profileLibrary,
                    context: .init(asShotTemperature: frame.metadata.asShotTemperature, asShotTint: frame.metadata.asShotTint),
                    cameraModel: frame.metadata.cameraModel, recipeID: recipe.id, allowUnresolvedSimulation: true)
                stack.fingerprint = try SourceFingerprint.compute(for: url)
                try Sidecar.save(stack, forImageAt: url)
                applied += 1
                if coordinator.sourceURL == url { adoptRecipeStack(stack) }
            }
            statusLine = selection.status(applied: applied)
        } catch {
            statusLine = selection.status(applied: applied) + " — \(error)"
            throw error
        }
    }
}
