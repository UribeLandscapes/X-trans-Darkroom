import Foundation
import ShortcutLogic
import EditModel

@MainActor enum ShortcutChecks {
    static func run(_ c: Checks) {
        c.suite("Shortcut catalog and pure policies") { c in
            let entries = ShortcutCatalog.entries
            c.expect(Set(entries.map(\.id)).count == entries.count, "shortcut IDs are unique")
            var collisions: [String] = []
            for (i, a) in entries.enumerated() {
                for b in entries.dropFirst(i + 1) where a.key == b.key && a.modifiers == b.modifiers && a.scope.overlaps(b.scope) {
                    collisions.append(a.id + " / " + b.id)
                }
            }
            c.expect(collisions.isEmpty, "no overlapping shortcuts: \(collisions)")
            let required = "grid loupe develop libraryModule developModule inspector panels fullscreen fullscreenMenu lights bar help info previous next enter zoom space zoomIn zoomOut fit actual fill before sideBySide topBottom splitLR splitTB clipping whiteBalance monochrome crop reset sliderPrevious sliderNext sliderIncrease sliderDecrease sliderIncreaseLarge sliderDecreaseLarge sliderPlus copy copyAll paste pastePrevious export import open undo redo rotateLeft rotateRight escape"
            for id in required.split(separator: " ").map(String.init) {
                c.expect(entries.contains { $0.id == id }, "Lightroom mapping present: \(id)")
            }
            for id in (0...5).map({ "rating\($0)" }) + ["ratingUp", "ratingDown", "pick", "reject", "unflag", "togglePick"] {
                let base = entries.first { $0.id == id }
                let advance = entries.first { $0.id == id + "Advance" }
                c.expect(base != nil && advance?.action == base?.action && advance?.advance == true && advance?.modifiers == .shift,
                         "annotation and auto-advance: \(id)")
            }
            c.expect(ShortcutPolicy.key("\u{19}", code: 48, modifiers: .shift) == "\t", "Shift-Tab matches Tab catalog entry")
            c.expect(ShortcutPolicy.key("\u{3}", code: 76, modifiers: []) == "\r", "keypad Enter opens selection")
            for (glyph, base) in [("#", "3"), ("+", "="), ("{", "["), ("~", "`")] {
                c.expect(ShortcutPolicy.key(glyph, code: 0, modifiers: .shift) == base, "shifted glyph normalizes: \(glyph)")
            }
            c.expect(entries.first { $0.id == "paste" }?.scope == .global, "paste retains Library batch settings support")
            let expected: [Double?] = [nil, 0.25, 0.5, 1, 2, 4, 8, 16]
            for i in expected.indices {
                c.expect(ShortcutPolicy.zoom(expected[i], direction: 1) == expected[min(i + 1, 7)], "zoom next rung \(i)")
                c.expect(ShortcutPolicy.zoom(expected[i], direction: -1) == expected[max(i - 1, 0)], "zoom previous rung \(i)")
            }
            c.expect(ShortcutPolicy.zoom(0.7, direction: 1) == 1 && ShortcutPolicy.zoom(0.7, direction: -1) == 0.5, "arbitrary zoom joins ladder")
            for rating in 0...5 {
                c.expect(ShortcutPolicy.rating(rating, delta: 1) == min(5, rating + 1), "rating increment clamps")
                c.expect(ShortcutPolicy.rating(rating, delta: -1) == max(0, rating - 1), "rating decrement clamps")
            }
            c.expect(ShortcutPolicy.index(0, delta: -1, count: 3) == 0, "previous does not wrap")
            c.expect(ShortcutPolicy.index(2, delta: 1, count: 3) == 2, "next does not wrap")
            c.expect(ShortcutPolicy.index(nil, delta: 1, count: 0) == nil, "empty library has no selection")
            c.expect(ShortcutPolicy.index(nil, delta: -1, count: 3) == 0, "first navigation selects first photo")
            for scope in [ShortcutScope.global, .library, .develop, .gridSelection] {
                for library in [true, false] {
                    c.expect(!ShortcutPolicy.accepts(textInput: true, sheet: false, scope: scope, library: library, canDevelop: true), "text input yields: \(scope)")
                    c.expect(!ShortcutPolicy.accepts(textInput: false, sheet: true, scope: scope, library: library, canDevelop: true), "sheet yields: \(scope)")
                }
            }
            c.expect(!ShortcutPolicy.accepts(textInput: false, sheet: false, scope: .develop, library: true, canDevelop: true), "Develop-only keys yield in Library")
            c.expect(!ShortcutPolicy.accepts(textInput: false, sheet: false, scope: .develop, library: false, canDevelop: false), "Develop-only keys yield without image")
            c.expect(ShortcutPolicy.accepts(textInput: false, sheet: false, scope: .develop, library: false, canDevelop: true), "Develop keys accepted with image")
            var clock = 10.0
            var coalescing = SliderCoalescing()
            var history = EditHistory(EditStack())
            var stack = EditStack()
            for value in 1...3 {
                stack.light.exposure = Double(value)
                if coalescing.press(id: "exposure", now: clock) { history.coalesce(stack) }
                else { history.commit(stack) }
                clock += 0.2
            }
            c.expect(history.undo()?.light.exposure == 0 && !history.canUndo, "three presses in 500 ms form one undo entry")
            c.expect(history.redo()?.light.exposure == 3, "coalesced redo restores final value")
            c.expect(!coalescing.press(id: "exposure", now: 11), "pause begins another commit")
            c.expect(!coalescing.press(id: "contrast", now: 11.1), "changing slider begins another commit")
            coalescing.reset()
            c.expect(!coalescing.press(id: "contrast", now: 11.2), "intervening edit breaks coalescing")
            let root = Checks.repoRoot()
            let dispatch = try String(contentsOf: root.appendingPathComponent("Sources/App/EditorShortcuts.swift"), encoding: .utf8)
            c.expect(dispatch.contains("switch entry.action") && dispatch.contains("case .escape:"), "App compiles exhaustive action dispatch")
            let menus = try String(contentsOf: root.appendingPathComponent("Sources/App/DevelopCommands.swift"), encoding: .utf8)
            c.expect(menus.contains("ShortcutCatalog.entries") && menus.contains("entry.eventModifiers"), "menus use catalog keys and modifiers")
        }
    }
}
