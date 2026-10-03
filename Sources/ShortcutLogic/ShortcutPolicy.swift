import Foundation

public enum ShortcutPolicy {
    public static func key(_ characters: String, code: UInt16, modifiers: ShortcutModifiers) -> String {
        switch code {
        case 48: return "\t" // AppKit emits backtab for Shift-Tab.
        case 36, 76: return "\r"
        case 53: return "\u{1b}"
        case 123: return "←"
        case 124: return "→"
        default: break
        }
        let key = characters.lowercased()
        let shifted = ["!":"1", "@":"2", "#":"3", "$":"4", "%":"5", ")":"0", "{":"[", "}":"]", "~":"`", "+":"=", "_":"-"]
        return modifiers.contains(.shift) ? shifted[key] ?? key : key
    }
    public static let zoomSteps = [0.25, 0.5, 1, 2, 4, 8, 16]
    /// nil is Fit, always the first rung regardless of image size.
    public static func zoom(_ current: Double?, direction: Int) -> Double? {
        guard let current else { return direction > 0 ? zoomSteps[0] : nil }
        if direction > 0 { return zoomSteps.first { $0 > current + 0.000001 } ?? zoomSteps.last }
        return zoomSteps.last { $0 < current - 0.000001 }
    }
    public static func rating(_ current: Int, delta: Int) -> Int { min(5, max(0, current + delta)) }
    public static func index(_ current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return min(count - 1, max(0, current + delta))
    }
    public static func accepts(textInput: Bool, sheet: Bool, scope: ShortcutScope, library: Bool, canDevelop: Bool) -> Bool {
        !textInput && !sheet && scope.active(library: library) && (scope != .develop || canDevelop)
    }
}
public struct SliderCoalescing {
    private var last: (String, TimeInterval)?
    public init() {}
    public mutating func reset() { last = nil }
    public mutating func press(id: String, now: TimeInterval) -> Bool {
        defer { last = (id, now) }
        guard let last else { return false }
        return last.0 == id && now >= last.1 && now - last.1 <= 0.5
    }
}
