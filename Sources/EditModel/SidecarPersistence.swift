import Foundation

/// Decides when an edit stack may be written to a sidecar, and remembers failures.
///
/// Two data-loss guards: a stack is only written to the photo it was opened for (a failed
/// open must never write the failed photo's settings over the previous photo's sidecar),
/// and a failed write keeps the edits marked dirty with a message, so the next commit
/// retries and the user is told, instead of the error being swallowed.
public struct SidecarPersistence {
    public private(set) var stackURL: URL?
    public private(set) var isDirty = false
    public private(set) var failure: String?

    public init() {}

    /// Call whenever the editor's stack is replaced for a (possibly failed-to-open) photo.
    public mutating func adopt(stackFor url: URL?) {
        stackURL = url?.standardizedFileURL
        isDirty = false
        failure = nil
    }

    /// Returns true only when the sidecar was actually written.
    @discardableResult
    public mutating func save(_ stack: EditStack, currentSource: URL?,
                              write: (EditStack, URL) throws -> Void = { try Sidecar.save($0, forImageAt: $1) }) -> Bool {
        guard let source = currentSource?.standardizedFileURL, source == stackURL else { return false }
        do {
            try write(stack, source)
            isDirty = false
            failure = nil
            return true
        } catch {
            isDirty = true
            failure = "Could not save edits for \(source.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    public enum SwitchDecision: Equatable { case proceed, blocked(message: String) }

    /// Call before replacing the open photo. Unsaved edits are retried first; if the write
    /// still fails the switch is blocked and the edits stay dirty until saved or discarded.
    public mutating func prepareSwitch(_ stack: EditStack, currentSource: URL?,
                                       write: (EditStack, URL) throws -> Void = { try Sidecar.save($0, forImageAt: $1) }) -> SwitchDecision {
        guard isDirty else { return .proceed }
        if save(stack, currentSource: currentSource, write: write) { return .proceed }
        return .blocked(message: failure ?? "Could not save edits")
    }

    /// The user explicitly gave up the unsaved edits.
    public mutating func discardUnsavedEdits() {
        isDirty = false
        failure = nil
    }
}
