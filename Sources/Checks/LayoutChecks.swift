import Foundation

enum LayoutChecks {
    static func run(_ c: Checks) {
        c.suite("Detail-column minimum width") { c in
            // macOS 27 can loop split-view min-size updates when horizontal chrome cannot shrink.
            for file in ["LibraryView.swift", "CanvasBar.swift", "CanvasArea.swift", "CanvasInfoOverlay.swift", "EditorView.swift"] {
                let source = try String(contentsOf: Checks.repoRoot().appendingPathComponent("Sources/App/\(file)"), encoding: .utf8)
                c.expect(source.range(of: #"\.fixedSize\s*\(\s*\)"#, options: .regularExpression) == nil,
                         "\(file): no unconstrained fixedSize in the detail column")
            }
        }
    }
}
