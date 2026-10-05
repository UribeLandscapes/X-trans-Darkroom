import Foundation
import EditModel

enum QuitGuardChecks {
    static func run(_ c: Checks) {
        c.suite("Quit guard protects unsaved edits") { c in
            var prompts = 0
            let clean = QuitGuard.decide(isDirty: false, retry: { "x" }, ask: { _ in prompts += 1; return .cancel })
            c.expect(clean == .terminateNow && prompts == 0, "clean state quits without a prompt")
            let healed = QuitGuard.decide(isDirty: true, retry: { nil }, ask: { _ in prompts += 1; return .cancel })
            c.expect(healed == .terminateNow && prompts == 0, "dirty edits that save on retry quit without a prompt")
            let cancel = QuitGuard.decide(isDirty: true, retry: { "disk full" }, ask: { _ in .cancel })
            c.expect(cancel == .cancel, "failed save then Cancel keeps the app open")
            let discard = QuitGuard.decide(isDirty: true, retry: { "disk full" }, ask: { _ in .quitWithoutSaving })
            c.expect(discard == .terminateNow, "failed save then Quit Without Saving quits")
            var attempts = 0
            let again = QuitGuard.decide(isDirty: true, retry: { attempts += 1; return attempts < 3 ? "busy" : nil },
                                         ask: { _ in .tryAgain })
            c.expect(again == .terminateNow && attempts == 3, "Try Again retries until the save succeeds; attempts=\(attempts)/3")
            var shown = ""
            _ = QuitGuard.decide(isDirty: true, retry: { "Could not save a.RAF" }, ask: { shown = $0; return .cancel })
            c.expect(shown == "Could not save a.RAF", "prompt carries the failure message")
            var real = SidecarPersistence()
            let url = URL(fileURLWithPath: "/tmp/q.RAF")
            real.adopt(stackFor: url)
            struct Boom: Error {}
            _ = real.save(EditStack(), currentSource: url, write: { _, _ in throw Boom() })
            c.expect(real.isDirty, "failed write leaves persistence dirty, so quit guard engages")
        }
    }
}
