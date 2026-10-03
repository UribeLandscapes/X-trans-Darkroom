import SwiftUI

/// Only mounted sliders register, so collapsed sections never receive keyboard edits.
@MainActor public final class SliderKeyboard: ObservableObject {
    struct Entry { var y: CGFloat; var step: (Int) -> Void }
    private var entries: [UUID: Entry] = [:]
    @Published public private(set) var selected: UUID?
    public init() {}
    func register(_ id: UUID, y: CGFloat, step: @escaping (Int) -> Void) { entries[id] = Entry(y: y, step: step) }
    func remove(_ id: UUID) { entries.removeValue(forKey: id); if selected == id { selected = nil } }
    public func select(_ direction: Int) {
        let ids = entries.keys.sorted { entries[$0]!.y < entries[$1]!.y }
        guard !ids.isEmpty else { return }
        let index = selected.flatMap { ids.firstIndex(of: $0) }
        selected = ids[index.map { min(ids.count - 1, max(0, $0 + direction)) } ?? (direction > 0 ? 0 : ids.count - 1)]
    }
    public func step(_ amount: Int) {
        guard let selected else { return }
        entries[selected]?.step(amount)
    }
}
private struct SliderKeyboardKey: EnvironmentKey { static let defaultValue: SliderKeyboard? = nil }
private struct SliderKeyboardCommitKey: EnvironmentKey { static let defaultValue: (@MainActor (String) -> Void)? = nil }
extension EnvironmentValues {
    public var sliderKeyboard: SliderKeyboard? {
        get { self[SliderKeyboardKey.self] }
        set { self[SliderKeyboardKey.self] = newValue }
    }
    public var sliderKeyboardCommit: (@MainActor (String) -> Void)? {
        get { self[SliderKeyboardCommitKey.self] }
        set { self[SliderKeyboardCommitKey.self] = newValue }
    }
}
struct SliderKeyboardHighlight: View {
    @ObservedObject var keyboard: SliderKeyboard
    let id: UUID
    var body: some View {
        RoundedRectangle(cornerRadius: 3).fill(keyboard.selected == id ? Studio.neutralSelection : Color.clear)
    }
}
