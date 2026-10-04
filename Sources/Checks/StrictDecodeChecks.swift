import Foundation
import EditModel

/// Audit HIGH: a sidecar with an invalid value must fail to decode (so the existing
/// load-failure lock protects it) instead of silently decoding to neutral.
enum StrictDecodeChecks {
    static func run(_ c: Checks) {
        c.suite("Strict sidecar decode (audit HIGH)") { c in
            func decodes(_ json: String) -> EditStack? {
                try? JSONDecoder().decode(EditStack.self, from: Data(json.utf8))
            }
            c.expect(decodes(#"{"light":{"exposure":"invalid"}}"#) == nil,
                     "wrong-typed Light value throws")
            c.expect(decodes(#"{"hsl":{"bands":{"red":{"hue":"x"}}}}"#) == nil,
                     "invalid nested HSL value throws")
            c.expect(decodes(#"{"curves":{"composite":"bad"}}"#) == nil,
                     "invalid curve throws")
            c.expect(decodes(#"{"curves":{"composite":{}}}"#)?.curves.composite == .identity,
                     "curve with missing points decodes to identity")
            c.expect(decodes(#"{"curves":{"red":{"points":null}}}"#)?.curves.red == .identity,
                     "curve with null points decodes to identity")
            c.expect(decodes(#"{"curves":{"composite":{"points":"bad"}}}"#) == nil,
                     "curve with malformed points throws")
            c.expect(decodes(#"{"custom":{"glowAmount":"bad"}}"#) == nil,
                     "invalid custom value throws")
            c.expect(decodes(#"{"profileID":5}"#) == nil, "wrong-typed top-level string throws")

            let sparse = decodes(#"{"light":{"exposure":1.5},"effects":null}"#)
            c.expect(sparse?.light.exposure == 1.5 && sparse?.light.contrast == 0
                     && sparse?.effects == .neutral && sparse?.color == .neutral,
                     "missing fields, missing groups and null still decode with defaults")
            c.expect(decodes("{}") == EditStack(), "empty object still decodes to a fresh stack")

            let dir = try Checks.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let raf = dir.appendingPathComponent("DSCF0002.RAF")
            try Data("raw".utf8).write(to: raf)
            let bad = Data(#"{"light":{"exposure":"invalid"}}"#.utf8)
            let side = Sidecar.url(forImageAt: raf)
            try bad.write(to: side)
            let outcome = Sidecar.loadOutcome(forImageAt: raf)
            var failed = false
            if case .failed = outcome { failed = true }
            c.expect(failed, "malformed-field sidecar loads as .failed")
            var persistence = SidecarPersistence()
            if case .failed(let m) = outcome { persistence.adopt(stackFor: raf, loadFailure: m) }
            var stack = EditStack(); stack.light.exposure = 2
            c.expect(!persistence.save(stack, currentSource: raf), "save refuses for the malformed sidecar")
            c.expect(try Data(contentsOf: side) == bad, "malformed sidecar bytes unchanged after save attempt")
        }
    }
}
