import SwiftUI
import ImageCanvas
import StudioTheme

/// Native `.toolbar` replacing the old capsule title bar. Segmented Library/Develop picker is
/// the principal item; Open/Undo/Redo/Export/Focus/Reset/Inspector are primary actions - macOS
/// 26 gives these Liquid Glass for free, so `chromeGlass` is no longer used here.
struct DevelopToolbarContent: ToolbarContent {
    @ObservedObject var editor: EditorModel
    @ObservedObject var coordinator: RenderCoordinator
    @Binding var libraryMode: Bool
    let focusMode: Bool
    let showInspector: Bool
    let exportDisabled: Bool
    let blipBusy: Bool
    let onBlip: () -> Void
    let onExport: () -> Void
    let onToggleFocus: () -> Void
    let onToggleInspector: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $libraryMode) {
                Text("Library").tag(true)
                Text("Develop").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        ToolbarItem(placement: .navigation) {
            Button { editor.presentOpenPanel() } label: { Label("Open", systemImage: StudioIcon.import.symbolName) }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { editor.undo() } label: { Label("Undo", systemImage: StudioIcon.undo.symbolName) }
                .disabled(!editor.canUndo)
            Button { editor.redo() } label: { Label("Redo", systemImage: StudioIcon.redo.symbolName) }
                .disabled(!editor.canRedo)
            Button(action: onExport) { Label("Export", systemImage: StudioIcon.export.symbolName) }
                .disabled(exportDisabled)
            if !libraryMode {
                Button(action: onBlip) { Label("Send to Phone", systemImage: BlipShare.symbol) }
                    .disabled(!coordinator.hasImage || !BlipShare.isInstalled || blipBusy)
                    .help(BlipShare.isInstalled ? "Send to Phone" : "Blip not installed")
            }
            Button(action: onToggleFocus) {
                Label(focusMode ? "Focus on" : "Focus", systemImage: StudioIcon.eyedropper.symbolName)
            }
            Button { editor.resetAll() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            Button(action: onToggleInspector) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide inspector" : "Show inspector")
        }
    }
}
