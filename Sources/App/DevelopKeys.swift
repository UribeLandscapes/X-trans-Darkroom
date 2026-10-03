import SwiftUI
import AppKit
import ShortcutLogic

/// Window-local shortcuts always yield to field editors and sheets.
struct DevelopKeys: NSViewRepresentable {
    let editor: EditorModel
    let perform: (ShortcutEntry, NSWindow) -> Void
    func makeNSView(context: Context) -> KeyView { KeyView(editor: editor, perform: perform) }
    func updateNSView(_ view: KeyView, context: Context) { view.perform = perform }
    final class KeyView: NSView {
        private var monitor: Any?
        private var spaceDown: TimeInterval?
        private var spaceDragged = false
        var perform: (ShortcutEntry, NSWindow) -> Void
        init(editor: EditorModel, perform: @escaping (ShortcutEntry, NSWindow) -> Void) {
            self.perform = perform
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDragged]) { [weak self, weak editor] event in
                guard let self, let editor, let window = self.window, event.window === window else { return event }
                if event.type == .leftMouseDragged { if self.spaceDown != nil { self.spaceDragged = true }; return event }
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                var mods: ShortcutModifiers = []
                if flags.contains(.command) { mods.insert(.command) }
                if flags.contains(.option) { mods.insert(.option) }
                if flags.contains(.control) { mods.insert(.control) }
                if flags.contains(.shift) { mods.insert(.shift) }
                guard !mods.contains(.command) else { return event }
                let key = ShortcutPolicy.key(event.charactersIgnoringModifiers ?? "", code: event.keyCode, modifiers: mods)
                guard let entry = ShortcutCatalog.entries.first(where: { $0.key == key && $0.modifiers == mods }),
                      ShortcutPolicy.accepts(textInput: window.firstResponder is NSTextInputClient,
                        sheet: !(window.attachedSheet == nil), scope: entry.scope,
                        library: editor.libraryMode, canDevelop: editor.canDevelop) else {
                    self.spaceDown = nil
                    return event
                }
                if key == " " {
                    if event.type == .keyDown {
                        if !event.isARepeat { self.spaceDown = event.timestamp; self.spaceDragged = false }
                    } else if let start = self.spaceDown {
                        self.spaceDown = nil
                        if event.timestamp - start < 0.3 && !self.spaceDragged { self.perform(entry, window) }
                    }
                    return nil
                }
                guard event.type == .keyDown else { return event }
                if event.isARepeat {
                    switch entry.action { case .sliderStep, .previous, .next: break; default: return nil }
                }
                self.perform(entry, window)
                return nil
            }
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
