import Foundation
import EditModel
import RecipeUI

extension LibraryModel {
    /// Destinations are resolved off the main actor (unopened Fuji RAFs need a decode for their
    /// as-shot start), then merged and saved here. A new paste cancels a running one; a scan cancels it too, except the scan this paste triggers itself
    /// (pasteTask is cleared first). Cancellation is checked after resolving and before every photo's write,
    /// so a cancelled paste writes nothing further (photos already written stay written).
    func pasteSettings(_ clipboard: SettingsClipboard, editor: EditorModel) {
        pasteTask?.cancel()
        pasteToken += 1
        let token = pasteToken
        let urls = selectedPaths.sorted().map { URL(fileURLWithPath: $0) }
        let leases = urls.map { access(for: $0.path) }
        let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
        let current = editor.coordinator.sourceURL.map { (url: $0, stack: editor.stack) }
        let profiles = editor.coordinator.profileLibrary
        editor.statusLine = "Pasting settings..."
        pasteTask = Task {
            defer {
                for (url, on) in zip(urls, scoped) where on { url.stopAccessingSecurityScopedResource() }
                withExtendedLifetime(leases) {}
            }
            let work = Task.detached {
                try LibraryExportStacks.resolveEach(urls: urls, current: current, profiles: profiles)
            }
            guard let resolved = try? await withTaskCancellationHandler(operation: { try await work.value },
                                                                       onCancel: { work.cancel() }) else { return finishCancelled(token, editor) }
            if Task.isCancelled { return finishCancelled(token, editor) }
            // Back on the main actor: the editor may have changed while resolving, so merge into its
            // live stack and re-read sidecars now. Cancelled before this point means zero writes.
            let outcome = LibraryExportStacks.applyPaste(
                urls: urls, resolved: resolved, source: clipboard.stack, sections: clipboard.sections,
                live: { editor.coordinator.sourceURL == $0 ? editor.stack : nil },
                load: { try Sidecar.load(forImageAt: $0) },
                save: { url, stack in
                    var stack = stack
                    stack.fingerprint = try SourceFingerprint.compute(for: url)
                    try Sidecar.save(stack, forImageAt: url)
                    return stack
                },
                isCancelled: { Task.isCancelled })
            for (url, stack) in outcome.written where editor.coordinator.sourceURL == url {
                editor.stack = stack; editor.live(); editor.commit()
            }
            let count = outcome.written.count, failures = outcome.failures
            editor.statusLine = "Pasted settings to \(count) photo(s)" + (failures > 0 ? "; \(failures) failed" : "")
            guard token == pasteToken else { return }
            self.pasteTask = nil
            self.scan()
        }
    }

    /// A cancelled paste leaves a newer paste's handle and status alone; only if it is still the
    /// current one (a scan cancelled it) does it clear its own handle and "Pasting settings..." status.
    private func finishCancelled(_ token: Int, _ editor: EditorModel) {
        guard token == pasteToken else { return }
        pasteTask = nil
        editor.statusLine = "Paste cancelled"
    }
}
