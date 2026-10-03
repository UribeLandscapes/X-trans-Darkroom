import SwiftUI
import AppKit
import ShortcutLogic
import ImagingCore
import LibraryLogic

extension EditorView {
    func shortcutEnabled(_ entry: ShortcutEntry) -> Bool {
        guard entry.enabledForCamera(isFujifilmRAF: editor.canUseCamera), entry.scope.active(library: libraryMode), entry.scope != .develop || editor.canDevelop else { return false }
        switch entry.action {
        case .undo: return editor.canUndo
        case .redo: return editor.canRedo
        case .paste: return editor.canPasteSettings
        case .pastePrevious: return editor.previousStack != nil
        case .export: return libraryMode ? !library.selectedPaths.isEmpty : coordinator.hasImage
        default: return true
        }
    }
    func performShortcut(_ entry: ShortcutEntry, window: NSWindow) {
        guard shortcutEnabled(entry) else { return }
        switch entry.action {
        case .library: libraryMode = true
        case .develop, .openSelection:
            if libraryMode, let row = library.selected { openPhoto(row.path) }
            else if coordinator.hasImage { libraryMode = false }
        case .inspector: showInspector.toggle()
        case .panels:
            let visible = columnVisibility == .detailOnly && !showInspector
            columnVisibility = visible ? .all : .detailOnly; showInspector = visible
        case .fullscreen: window.toggleFullScreen(nil)
        case .focus: toggleFocus()
        case .bar: showCanvasBar.toggle()
        case .help: showsShortcuts = true
        case .info: viewer.infoMode = (viewer.infoMode + 1) % 3
        case .previous: movePhoto(-1)
        case .next: movePhoto(1)
        case .rating, .ratingDelta, .flag, .togglePick: annotate(entry)
        case .zoom: viewer.toggleZoom()
        case .zoomIn: viewer.zoomIn()
        case .zoomOut: viewer.zoomOut()
        case .fit: viewer.zoomToFit()
        case .actual: viewer.zoom1to1()
        case .fill: viewer.zoomToFill()
        case .before: viewer.toggleBefore()
        case .comparison(let index):
            let modes: [BeforeAfterMode] = [.sideBySide, .topBottom, .splitLeftRight, .splitTopBottom]
            let mode = modes[index]
            viewer.setBeforeAfter(viewer.beforeAfterMode == mode ? .off : mode)
        case .clipping: viewer.toggleClipping()
        case .whiteBalance: editor.toggleWhiteBalancePicker()
        case .monochrome: editor.toggleBlackAndWhite()
        case .crop: expansion.geometry.toggle(); if expansion.geometry { showInspector = true }
        case .reset: editor.resetAll()
        case .sliderSelect(let direction): sliderKeyboard.select(direction)
        case .sliderStep(let amount): sliderKeyboard.step(amount)
        case .copy: editor.showsCopySettings = true
        case .copyAll: editor.copySettings(sections: .standard)
        case .paste: editor.pasteSettings()
        case .pastePrevious: editor.pasteSettingsFromPrevious()
        case .export: presentExport()
        case .importPhotos: library.addFolder()
        case .undo: editor.undo()
        case .redo: editor.redo()
        case .open: editor.presentOpenPanel()
        case .rotate(let direction):
            editor.stack.geometry.rotation = (editor.stack.geometry.rotation + direction + 4) % 4
            editor.live(); editor.commit()
        case .escape:
            if viewer.wbPickerActive { editor.cancelWhiteBalancePicker() }
            else if expansion.geometry { expansion.geometry = false }
            else if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }
    private var currentPath: String? { libraryMode ? library.selection : coordinator.sourceURL?.path }
    private func openPhoto(_ path: String) {
        guard libraryMode || coordinator.sourceURL?.path != path else { return }
        developAccess = library.access(for: path)
        library.selection = path; library.selectedPaths = [path]
        editor.open(URL(fileURLWithPath: path)); libraryMode = false
    }
    private func movePhoto(_ delta: Int) {
        guard let index = ShortcutPolicy.index(library.rows.firstIndex { $0.path == currentPath }, delta: delta, count: library.rows.count) else { return }
        let path = library.rows[index].path
        if libraryMode { library.selection = path; library.selectedPaths = [path] }
        else { openPhoto(path) }
    }
    private func annotate(_ entry: ShortcutEntry) {
        guard let path = currentPath, let row = library.record(for: path) else { return }
        // Capture the successor before annotation can remove this row from a filtered view.
        let index = library.rows.firstIndex { $0.path == path }
        let next = index.flatMap { $0 + 1 < library.rows.count ? library.rows[$0 + 1].path : nil }
        let key: LibraryKey
        switch entry.action {
        case .rating(let value): key = .rating(value)
        case .ratingDelta(let delta): key = .rating(ShortcutPolicy.rating(row.rating, delta: delta))
        case .flag(let value): key = .flag(value)
        case .togglePick: key = .flag(row.flag == 1 ? 0 : 1)
        default: return
        }
        library.annotate(key, path: path)
        if entry.advance, let next {
            if libraryMode { library.selection = next; library.selectedPaths = [next] }
            else { openPhoto(next) }
        }
    }
}
