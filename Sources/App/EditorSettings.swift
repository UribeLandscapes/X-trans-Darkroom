import SwiftUI
import EditModel
import ImagingCore

struct SettingsClipboard {
    let stack: EditStack
    let sections: EditStackSections
}

extension EditorModel {
    var canDevelop: Bool { !libraryMode && coordinator.hasImage }
    var canPasteSettings: Bool {
        settingsClipboard != nil && (libraryMode ? !selectedLibraryPaths.isEmpty : coordinator.hasImage)
    }
    func toggleWhiteBalancePicker() {
        guard canDevelop, !viewer.cropEditing else { return }
        wbPickerRevision += 1
        viewer.wbPickerActive.toggle()
        if viewer.wbPickerActive { viewer.setBeforeAfter(.off) }
        refreshPicker()
    }
    func cancelWhiteBalancePicker() {
        guard viewer.wbPickerActive else { return }
        wbPickerRevision += 1
        viewer.wbPickerActive = false; refreshPicker()
    }
    private func refreshPicker() {
        // A geometry-free preview makes displayed coordinates identical to decoded pixels.
        coordinator.wbPicking = viewer.wbPickerActive
        live(); coordinator.scheduleSettle(stack)
    }
    func pickWhiteBalance(at point: CGPoint) {
        guard viewer.wbPickerActive, !viewer.cropEditing, !wbPickerBusy else { return }
        wbPickerBusy = true
        let original = stack, revision = openRevision, pickerRevision = wbPickerRevision
        Task {
            defer { wbPickerBusy = false }
            let result = await coordinator.whiteBalance(at: point, stack: original)
            // A late sample must never overwrite a newer edit or a newly opened photo.
            guard viewer.wbPickerActive, !viewer.cropEditing, openRevision == revision, wbPickerRevision == pickerRevision, stack == original else { return }
            if let result {
                stack.color.temperature = result.temperature; stack.color.tint = result.tint
                viewer.wbPickerActive = false; refreshPicker(); commit()
            } else { statusLine = "Choose a non-black point inside the image." }
        }
    }

    func setBlackAndWhite(_ enabled: Bool) {
        guard canDevelop, stack.color.blackAndWhite != enabled else { return }
        stack.color.blackAndWhite = enabled; live(); commit()
    }
    func toggleBlackAndWhite() { setBlackAndWhite(!stack.color.blackAndWhite) }
    func copySettings(sections: EditStackSections) {
        guard canDevelop else { return }
        settingsClipboard = SettingsClipboard(stack: stack, sections: sections)
        showsCopySettings = false
    }
    func pasteSettings() {
        guard canPasteSettings, let clipboard = settingsClipboard else { return }
        if libraryMode { library?.pasteSettings(clipboard, editor: self) }
        else { applySettings(clipboard.stack, sections: clipboard.sections) }
    }
    func applySettings(_ source: EditStack, sections: EditStackSections) {
        stack = stack.merging(source, sections: sections); live(); commit()
    }
    func pasteSettingsFromPrevious() {
        guard canDevelop, let previousStack else { return }
        applySettings(previousStack, sections: .standard)
    }
}

struct CopySettingsSheet: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy Settings").font(.headline)
            ForEach(EditStackSection.allCases, id: \.self) { section in
                Toggle(section.rawValue, isOn: Binding(get: { editor.copySections.contains(section) }, set: {
                    if $0 { editor.copySections.insert(section) } else { editor.copySections.remove(section) }
                }))
            }
            HStack {
                Button("Check All") { editor.copySections = .all }
                Button("Check None") { editor.copySections = [] }
            }
            HStack {
                Button("Cancel") { editor.showsCopySettings = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy") { editor.copySettings(sections: editor.copySections) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 300)
    }
}
