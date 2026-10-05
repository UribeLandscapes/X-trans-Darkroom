import Foundation
import EditModel
import Profiles
import RecipeUI

enum ExportStacksChecks {
    @MainActor
    static func run(_ c: Checks) async {
        await c.suite("Library export resolves stacks off the main actor") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let profiles = ProfileLibrary(bundledDirectory: nil, userDirectory: dir.appendingPathComponent("missing"))
            let loadedURL = dir.appendingPathComponent("loaded.RAF")
            try Data("not a sidecar".utf8).write(to: Sidecar.url(forImageAt: loadedURL))
            var live = EditStack.freshOpenDefault(for: loadedURL)
            live.light.shadows = 42
            let current = (url: loadedURL, stack: live)
            let offMain = try await Task.detached {
                try LibraryExportStacks.resolve(urls: [loadedURL], current: current, profiles: profiles)
            }.value
            c.expect(offMain == [live], "loaded photo uses the editor stack, skipping its unreadable sidecar and any decode")
            let other = dir.appendingPathComponent("other.RAF")
            let unreadable = try? LibraryExportStacks.resolve(urls: [other, loadedURL], current: nil, profiles: profiles)
            c.expect(unreadable == nil, "an unreadable sidecar still fails the export as before")
            // Paste destinations: per-photo failures, first-open start for photos without sidecars.
            let plainURL = dir.appendingPathComponent("plain.jpg")
            let each = try await Task.detached {
                try LibraryExportStacks.resolveEach(urls: [other, plainURL, loadedURL], current: nil, profiles: profiles)
            }.value
            var okCount = 0, failCount = 0
            for r in each { if case .success = r { okCount += 1 } else { failCount += 1 } }
            c.expect(each.count == 3 && failCount == 1 && okCount == 2,
                     "paste resolution isolates one unreadable sidecar; ok=\(okCount)/2, failed=\(failCount)/1")
            if case .success(let plain) = each[1] {
                c.expect(plain == EditStack.freshOpenDefault(for: plainURL), "photo without sidecar starts from the first-open stack")
            } else { c.fail("photo without sidecar should resolve") }
            if case .success(let live2) = try LibraryExportStacks.resolveEach(urls: [loadedURL], current: current, profiles: profiles)[0] {
                c.expect(live2 == live, "paste onto the loaded photo uses the editor stack")
            } else { c.fail("loaded photo should use the editor stack") }
            let cancelled = await Task.detached { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try LibraryExportStacks.resolve(urls: [loadedURL], current: current, profiles: profiles); return false }
                catch is CancellationError { return true } catch { return false }
            }.value
            c.expect(cancelled, "export preparation stops when its task is cancelled")
        }
        await c.suite("Paste merges at save time and stops after cancel") { c in
            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let open = dir.appendingPathComponent("open.jpg"), appeared = dir.appendingPathComponent("appeared.jpg")
            let fresh = EditStack.freshOpenDefault(for: open)
            var live = fresh; live.light.shadows = 40
            var disk = fresh; disk.light.exposure = 0.7
            var clip = fresh; clip.color.saturation = 25
            let sections: EditStackSections = [.color]
            var saved: [URL: EditStack] = [:]
            let urls = [open, appeared]
            let resolved: [Swift.Result<EditStack, Error>] = [.success(fresh), .success(fresh)]
            func run(cancelled: Bool) -> (written: [(url: URL, stack: EditStack)], failures: Int) {
                LibraryExportStacks.applyPaste(
                    urls: urls, resolved: resolved, source: clip, sections: sections,
                    live: { $0 == open ? live : nil }, load: { $0 == appeared ? disk : nil },
                    save: { saved[$0] = $1; return $1 }, isCancelled: { cancelled })
            }
            _ = run(cancelled: false)
            c.expect(saved[open] == live.merging(clip, sections: sections), "open photo merges into the live stack, not the resolve-time one")
            c.expect(saved[appeared] == disk.merging(clip, sections: sections), "photo whose sidecar appeared after resolving uses that sidecar")
            saved = [:]
            let out = run(cancelled: true)
            c.expect(saved.isEmpty && out.written.isEmpty, "cancelled before save performs zero writes")
            struct Unreadable: Error {}
            saved = [:]
            let bad = LibraryExportStacks.applyPaste(
                urls: [open], resolved: [.success(fresh)], source: clip, sections: sections,
                live: { _ in live }, load: { _ in throw Unreadable() },
                save: { saved[$0] = $1; return $1 }, isCancelled: { false })
            c.expect(bad.failures == 0 && saved[open] == live.merging(clip, sections: sections),
                     "open photo pastes onto its live stack even when its sidecar is unreadable")
        }
    }
}
