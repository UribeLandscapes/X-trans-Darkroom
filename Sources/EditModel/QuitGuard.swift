import Foundation

/// Decides whether the app may quit while edits might be unsaved. Pure: the save retry and
/// the user prompt are injected, so the AppKit alert stays a thin shell around this.
public enum QuitGuard {
    public enum Choice: Equatable, Sendable { case tryAgain, quitWithoutSaving, cancel }
    public enum Outcome: Equatable, Sendable { case terminateNow, cancel }

    /// `retry` re-attempts the save and returns the failure message if edits are still unsaved
    /// (nil = saved or nothing to save). `ask` shows the failure and returns the user's choice.
    public static func decide(isDirty: Bool, retry: () -> String?, ask: (String) -> Choice) -> Outcome {
        guard isDirty else { return .terminateNow }
        while let failure = retry() {
            switch ask(failure) {
            case .tryAgain: continue
            case .quitWithoutSaving: return .terminateNow
            case .cancel: return .cancel
            }
        }
        return .terminateNow
    }
}
