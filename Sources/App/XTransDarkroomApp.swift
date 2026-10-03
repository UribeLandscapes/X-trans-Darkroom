import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EditModel
import ImageCanvas
import StudioTheme

@main
struct XTransDarkroomApp: App {
    @StateObject private var editor = EditorModel()

    var body: some Scene {
        WindowGroup("X-Trans Darkroom") {
            EditorView(editor: editor)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .commands {
            DevelopCommands()
            CommandMenu("Recipes") {
                Button("Recipe browser") { editor.showsRecipes = true }
                Button("Choose recipe spreadsheet...") { editor.chooseRecipeSpreadsheet() }
                Button("Reload recipes") {
                    editor.showsRecipes = true
                    Task { await editor.recipes.reload() }
                }
            }
        }
    }
}
