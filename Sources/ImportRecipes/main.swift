import Foundation
import Recipes

@main struct ImportRecipes {
    static func main() async {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: ImportRecipes <source.xlsx> <destination.xlsx>"); exit(2)
        }
        do {
            let source = URL(fileURLWithPath: CommandLine.arguments[1])
            let destination = URL(fileURLWithPath: CommandLine.arguments[2])
            let result = try RecipeImporter.read(source: source, destination: destination)
            print(result.summary(rowsWritten: 0))
            try await LocalRecipeStore(spreadsheet: destination).importIntoBlank(result.recipes)
            print("Import complete. Rows read: \(result.rowsRead); rows written: \(result.recipes.count)")
        } catch {
            print("Import failed: \(error). No successful write reported."); exit(1)
        }
    }
}
