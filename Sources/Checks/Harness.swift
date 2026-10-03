import Foundation

/// Minimal check harness.
///
/// Xcode is not installed on this machine, so neither XCTest nor swift-testing is
/// available to SwiftPM. `swift run Checks` is therefore the project's verification gate:
/// it exits non-zero on any failure, so it works as a pre-commit hook and as a CI step.
/// If Xcode is installed later this converts to swift-testing almost mechanically.
public final class Checks {
    private var failures: [String] = []
    private var passed = 0
    private var suite = ""

    public init() {}

    public func suite(_ name: String, _ body: (Checks) throws -> Void) {
        suite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
        do { try body(self) }
        catch { fail("threw \(error)") }
    }

    @MainActor
    public func suite(_ name: String, _ body: @MainActor (Checks) async throws -> Void) async {
        suite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
        do { try await body(self) }
        catch { fail("threw \(error)") }
    }

    public func expect(_ condition: Bool, _ what: String) {
        if condition {
            passed += 1
            print("  \u{001B}[32mok\u{001B}[0m   \(what)")
        } else {
            fail(what)
        }
    }

    public func expectClose(_ a: Double, _ b: Double, _ what: String, tolerance: Double = 1e-9) {
        expect(abs(a - b) <= tolerance, "\(what)  (got \(a), want \(b))")
    }

    public func fail(_ what: String) {
        failures.append("\(suite): \(what)")
        print("  \u{001B}[31mFAIL\u{001B}[0m \(what)")
    }

    public func finish() -> Never {
        print("\n\(passed) passed, \(failures.count) failed")
        for f in failures { print("  \u{001B}[31m✗\u{001B}[0m \(f)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    public static func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
        }
        return dir
    }

    public static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xtd-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
