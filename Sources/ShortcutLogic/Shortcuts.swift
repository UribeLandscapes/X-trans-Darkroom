import Foundation

public struct ShortcutModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1), shift = Self(rawValue: 2), option = Self(rawValue: 4), control = Self(rawValue: 8)
}
public enum ShortcutScope: String, Sendable { case global, library, develop, gridSelection
    public func overlaps(_ other: Self) -> Bool {
        self == .global || other == .global || self == other ||
        ([self, other].contains(.library) && [self, other].contains(.gridSelection))
    }
    public func active(library: Bool) -> Bool { self == .global || (library ? self != .develop : self == .develop) }
}
public enum ShortcutAction: Hashable, Sendable {
    case library, develop, inspector, panels, fullscreen, focus, bar, help, info, previous, next, openSelection
    case rating(Int), ratingDelta(Int), flag(Int), togglePick
    case zoom, zoomIn, zoomOut, fit, actual, fill, before, comparison(Int)
    case clipping, whiteBalance, monochrome, crop, reset, sliderSelect(Int), sliderStep(Int)
    case copy, copyAll, paste, pastePrevious, export, importPhotos, undo, redo, open, rotate(Int), escape
}
public struct ShortcutEntry: Identifiable, Sendable {
    public let id: String
    public let key: String
    public let modifiers: ShortcutModifiers
    public let scope: ShortcutScope
    public let title: String
    public let section: String
    public let action: ShortcutAction
    public var advance = false
    public func enabledForCamera(isFujifilmRAF: Bool) -> Bool {
        ShortcutCatalog.enabledForCamera(section: section, isFujifilmRAF: isFujifilmRAF)
    }
    public var caps: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") +
        (["\t": "Tab", " ": "Space", "\r": "Return", "\u{1b}": "Esc" ][key] ?? key.uppercased())
    }
}
public enum ShortcutCatalog {
    // Recipe commands belong to Recipes even when also surfaced in menus or the cheat sheet.
    public static func enabledForCamera(section: String, isFujifilmRAF: Bool) -> Bool {
        section != "Recipes" || isFujifilmRAF
    }
    public static let entries: [ShortcutEntry] = {
        var result: [ShortcutEntry] = []
        func add(_ id: String, _ key: String, _ mods: ShortcutModifiers = [], _ scope: ShortcutScope = .global,
                 _ title: String, _ section: String, _ action: ShortcutAction) {
            result.append(.init(id: id, key: key, modifiers: mods, scope: scope, title: title, section: section, action: action))
        }
        add("grid", "g", [], .global, "Library grid", "Views", .library)
        add("loupe", "e", [], .global, "Open in Develop (loupe substitute)", "Views", .develop)
        add("develop", "d", [], .global, "Develop selected photo", "Views", .develop)
        add("libraryModule", "1", [.command, .option], .global, "Library", "Window", .library)
        add("developModule", "2", [.command, .option], .global, "Develop", "Window", .develop)
        add("inspector", "\t", [], .global, "Toggle inspector", "Views", .inspector)
        add("panels", "\t", .shift, .global, "Toggle both panels", "Views", .panels)
        add("fullscreen", "f", [], .global, "Toggle full screen", "Views", .fullscreen)
        add("fullscreenMenu", "f", [.command, .shift], .global, "Toggle full screen", "Window", .fullscreen)
        add("lights", "l", [], .global, "Lights Out (two states)", "Views", .focus)
        add("bar", "t", [], .develop, "Toggle canvas bar", "Views", .bar)
        add("help", "/", .command, .global, "Keyboard Shortcuts", "Help", .help)
        add("info", "i", [], .develop, "Cycle photo information", "Views", .info)
        add("previous", "←", [], .global, "Previous photo", "Navigation", .previous)
        add("next", "→", [], .global, "Next photo", "Navigation", .next)
        add("enter", "\r", [], .gridSelection, "Develop selected photo", "Navigation", .openSelection)
        for value in 0...5 { add("rating\(value)", String(value), [], .global, "Rate \(value) stars", "Rating and flags", .rating(value)) }
        add("ratingUp", "]", [], .global, "Increase rating", "Rating and flags", .ratingDelta(1))
        add("ratingDown", "[", [], .global, "Decrease rating", "Rating and flags", .ratingDelta(-1))
        for (id, key, title, value) in [("pick", "p", "Pick", 1), ("reject", "x", "Reject", -1), ("unflag", "u", "Unflag", 0)] {
            add(id, key, [], .global, title, "Rating and flags", .flag(value))
        }
        add("togglePick", "`", [], .global, "Toggle pick", "Rating and flags", .togglePick)
        let annotations = result.filter { $0.section == "Rating and flags" }
        for entry in annotations {
            result.append(.init(id: entry.id + "Advance", key: entry.key, modifiers: .shift, scope: entry.scope,
                title: entry.title + " and advance", section: entry.section, action: entry.action, advance: true))
        }
        add("zoom", "z", [], .develop, "Toggle fit / last zoom", "Zoom", .zoom)
        add("space", " ", [], .develop, "Tap: toggle zoom; hold: pan", "Zoom", .zoom)
        add("zoomIn", "=", .command, .develop, "Zoom in", "Zoom", .zoomIn)
        add("zoomOut", "-", .command, .develop, "Zoom out", "Zoom", .zoomOut)
        add("fit", "0", .command, .develop, "Fit", "Zoom", .fit)
        add("actual", "0", [.command, .option], .develop, "100%", "Zoom", .actual)
        add("fill", "0", [.command, .shift], .develop, "Fill", "Zoom", .fill)
        add("before", "\\", [], .develop, "Before only", "Before / After", .before)
        for (id, mods, title, value) in [("sideBySide", ShortcutModifiers(), "Left / Right", 0), ("topBottom", .option, "Top / Bottom", 1), ("splitLR", .shift, "Split Left / Right", 2), ("splitTB", [.shift, .option], "Split Top / Bottom", 3)] {
            add(id, "y", mods, .develop, title, "Before / After", .comparison(value))
        }
        add("clipping", "j", [], .develop, "Clipping", "Develop", .clipping)
        add("whiteBalance", "w", [], .develop, "White balance picker", "Develop", .whiteBalance)
        add("monochrome", "v", [], .develop, "Black & White", "Develop", .monochrome)
        add("crop", "r", [], .develop, "Toggle Geometry / Crop", "Develop", .crop)
        add("reset", "r", [.command, .shift], .develop, "Reset all settings", "Develop", .reset)
        add("sliderPrevious", ",", [], .develop, "Previous slider", "Sliders", .sliderSelect(-1))
        add("sliderNext", ".", [], .develop, "Next slider", "Sliders", .sliderSelect(1))
        for (id, key, sign) in [("sliderIncrease", "=", 1), ("sliderDecrease", "-", -1)] {
            add(id, key, [], .develop, sign > 0 ? "Increase slider 1%" : "Decrease slider 1%", "Sliders", .sliderStep(sign))
            add(id + "Large", key, .shift, .develop, "Adjust slider 10%", "Sliders", .sliderStep(sign * 10))
        }
        add("sliderPlus", "+", [], .develop, "Increase slider 1%", "Sliders", .sliderStep(1))
        for (id, key, mods, title, action) in [
            ("copy", "c", ShortcutModifiers([.command, .shift]), "Copy Settings…", ShortcutAction.copy),
            ("copyAll", "c", [.command, .option], "Copy All Settings", .copyAll),
            ("paste", "v", [.command, .shift], "Paste Settings", .paste),
            ("pastePrevious", "v", [.command, .option], "Paste Settings from Previous", .pastePrevious),
            ("rotateLeft", "[", .command, "Rotate left", .rotate(-1)),
            ("rotateRight", "]", .command, "Rotate right", .rotate(1))] {
            add(id, key, mods, action == .paste ? .global : .develop, title, "Develop", action)
        }
        add("export", "e", [.command, .shift], .global, "Export…", "File", .export)
        add("import", "i", [.command, .shift], .global, "Import: Add folder…", "File", .importPhotos)
        add("open", "o", .command, .global, "Open Image…", "File", .open)
        add("undo", "z", .command, .develop, "Undo", "Edit", .undo)
        add("redo", "z", [.command, .shift], .develop, "Redo", "Edit", .redo)
        add("escape", "\u{1b}", [], .global, "Exit WB, Crop, then full screen", "Views", .escape)
        return result
    }()
    public static let unavailable = ["⌘⇧U — Auto Tone", "6–9 — Colour labels", "⌘' — Virtual copy", "⌘E — Edit in Photoshop", "⌘K — Keywording", "B — Quick collection", "S — Soft proofing", "C — Compare", "N — Survey", "M / ⇧M — Local masking", "Q — Spot removal", "K — Adjustment brush", "O — Mask overlay"]
}
