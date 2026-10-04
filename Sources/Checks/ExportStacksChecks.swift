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
            let cancelled = await Task.detached { () -> Bool in
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try LibraryExportStacks.resolve(urls: [loadedURL], current: current, profiles: profiles); return false }
                catch is CancellationError { return true } catch { return false }
            }.value
            c.expect(cancelled, "export preparation stops when its task is cancelled")
        }
    }
}
