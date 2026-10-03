import SwiftUI
import AppKit
import ShortcutLogic

struct ShortcutHandler {
    let run: (ShortcutEntry, NSWindow) -> Void
    let enabled: (ShortcutEntry) -> Bool
}
private struct ShortcutHandlerKey: FocusedValueKey { typealias Value = ShortcutHandler }
extension FocusedValues {
    var shortcutHandler: ShortcutHandler? {
        get { self[ShortcutHandlerKey.self] }
        set { self[ShortcutHandlerKey.self] = newValue }
    }
}
struct DevelopCommands: Commands {
    @FocusedValue(\.shortcutHandler) private var handler
    var body: some Commands {
        CommandGroup(replacing: .newItem) { items("File") }
        CommandGroup(replacing: .undoRedo) { items("Edit") }
        CommandGroup(after: .windowArrangement) { items("Window") }
        CommandGroup(after: .help) { items("Help") }
        CommandMenu("Develop") { items("Develop"); items("Zoom") }
    }
    @ViewBuilder private func items(_ section: String) -> some View {
        ForEach(ShortcutCatalog.entries.filter { $0.section == section }) { entry in
            if entry.modifiers.contains(.command) {
                Button(entry.title) { run(entry) }
                    .keyboardShortcut(KeyEquivalent(entry.key.first!), modifiers: entry.eventModifiers)
                    .disabled(handler?.enabled(entry) != true)
            } else {
                // A visible hint is safe; a single-letter menu equivalent steals field input.
                Button("\(entry.title) (\(entry.caps))") { run(entry) }
                    .disabled(handler?.enabled(entry) != true)
            }
        }
    }
    private func run(_ entry: ShortcutEntry) {
        if let window = NSApp.keyWindow { handler?.run(entry, window) }

    }
}
extension ShortcutEntry {
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        return result
    }
}
