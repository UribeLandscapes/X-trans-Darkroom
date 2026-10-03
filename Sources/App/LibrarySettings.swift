import Foundation
import EditModel

extension LibraryModel {
    func pasteSettings(_ clipboard: SettingsClipboard, editor: EditorModel) {
        var count = 0, failures = 0
        for path in selectedPaths.sorted() {
            let url = URL(fileURLWithPath: path)
            let lease = access(for: path)
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                withExtendedLifetime(lease) {}
            }
            do {
                var destination = try Sidecar.load(forImageAt: url) ?? .freshOpenDefault(for: url)
                if editor.coordinator.sourceURL == url { destination = editor.stack }
                destination = destination.merging(clipboard.stack, sections: clipboard.sections)
                destination.fingerprint = try SourceFingerprint.compute(for: url)
                try Sidecar.save(destination, forImageAt: url)
                if editor.coordinator.sourceURL == url {
                    editor.stack = destination; editor.live(); editor.commit()
                }
                count += 1
            } catch { failures += 1 }
        }
        editor.statusLine = "Pasted settings to \(count) photo(s)" + (failures > 0 ? "; \(failures) failed" : "")
        scan()
    }
}
