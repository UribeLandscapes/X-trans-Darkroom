import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EditModel
import ImageCanvas
import StudioTheme

/// Thin AppKit shell: asks EditorModel whether quitting would lose unsaved edits.
@MainActor
final class QuitDelegate: NSObject, NSApplicationDelegate {
    static weak var editor: EditorModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor = Self.editor else { return .terminateNow }
        return editor.mayTerminate(ask: Self.prompt) ? .terminateNow : .terminateCancel
    }

    private static func prompt(_ failure: String) -> QuitGuard.Choice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Your edits could not be saved"
        alert.informativeText = failure
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Quit Without Saving")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .tryAgain
        case .alertSecondButtonReturn: return .quitWithoutSaving
        default: return .cancel
        }
    }
}

@main
struct XTransDarkroomApp: App {
    @NSApplicationDelegateAdaptor(QuitDelegate.self) private var quitDelegate
    @StateObject private var editor = EditorModel()

    var body: some Scene {
        Window("X-Trans Darkroom", id: "main") {
            EditorView(editor: editor)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear { QuitDelegate.editor = editor }
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
