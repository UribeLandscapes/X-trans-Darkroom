import Foundation

/// Bounded undo/redo over immutable stacks (Build plan §2).
public struct EditHistory: Sendable {
    private var past: [EditStack] = []
    private var future: [EditStack] = []
    public private(set) var current: EditStack
    public let limit: Int

    public init(_ initial: EditStack, limit: Int = 100) {
        self.current = initial
        self.limit = limit
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Commit a new state. Called once on slider release, never per frame -
    /// a drag must not produce 400 undo entries.
    public mutating func commit(_ next: EditStack) {
        guard next != current else { return }
        past.append(current)
        if past.count > limit { past.removeFirst() }
        future.removeAll()
        current = next
    }

    /// Replace the latest keyboard step while preserving its original undo baseline.
    public mutating func coalesce(_ next: EditStack) { current = next; future.removeAll() }

    @discardableResult
    public mutating func undo() -> EditStack? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        current = previous
        return current
    }

    @discardableResult
    public mutating func redo() -> EditStack? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        current = next
        return current
    }
}
