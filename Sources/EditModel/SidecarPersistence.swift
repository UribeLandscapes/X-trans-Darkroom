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

    /// Set when the photo's existing sidecar could not be read. While set, nothing is
    /// written for that photo, so the unreadable file is never overwritten.
    public private(set) var loadFailure: String?
    public var isLockedByLoadFailure: Bool { loadFailure != nil }

    /// The user explicitly chose to replace the unreadable sidecar; the next save writes.
    public mutating func overrideLoadFailure() {
        loadFailure = nil
    }

    /// Call whenever the editor's stack is replaced for a (possibly failed-to-open) photo.
    public mutating func adopt(stackFor url: URL?) {
        stackURL = url?.standardizedFileURL
        isDirty = false
        failure = nil
        loadFailure = nil
    }

    /// Same as `adopt(stackFor:)`, but remembers that the photo's sidecar failed to load.
    public mutating func adopt(stackFor url: URL?, loadFailure message: String?) {
        adopt(stackFor: url)
        self.loadFailure = message
    }

    /// Returns true only when the sidecar was actually written.
    @discardableResult
    public mutating func save(_ stack: EditStack, currentSource: URL?,
                              write: (EditStack, URL) throws -> Void = { try Sidecar.save($0, forImageAt: $1) }) -> Bool {
        guard let source = currentSource?.standardizedFileURL, source == stackURL else { return false }
        // Unreadable sidecar on disk: never overwrite it, and don't pile up dirty state or block switches.
        guard loadFailure == nil else { return false }
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

    /// Status line after "Reset Edits and Overwrite": success only if the write happened.
    public static func resetOverwriteStatus(saved: Bool, failure: String?, fileName: String) -> String {
        guard saved else { return failure ?? "Could not save edits for \(fileName)" }
        return "Replaced the unreadable edits file for \(fileName)."
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
