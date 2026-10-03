import Foundation
import os

/// Build plan §2 sets a hard budget: sustained sub-8.3 ms interactive frames at 120 Hz,
/// and a settle render under 350 ms at 40 MP.
///
/// Instruments ships with Xcode, which is not installed here, so the app measures itself:
/// every render records its wall time and the panel reports p50/p95/max. That is the
/// verification instrument for Phase 1 and Phase 2 on this machine.
public final class FrameStats: @unchecked Sendable {
    public static let shared = FrameStats()

    private let lock = OSAllocatedUnfairLock(initialState: Samples())
    private struct Samples {
        var interactive: [Double] = []
        var settle: [Double] = []
    }

    public enum Kind: Sendable { case interactive, settle }

    /// Rolling window - long enough for a stable p95, short enough to reflect the last drag.
    private let window = 600

    public func record(_ kind: Kind, seconds: Double) {
        lock.withLock { s in
            switch kind {
            case .interactive:
                s.interactive.append(seconds * 1000)
                if s.interactive.count > window { s.interactive.removeFirst() }
            case .settle:
                s.settle.append(seconds * 1000)
                if s.settle.count > window { s.settle.removeFirst() }
            }
        }
    }

    public func reset() {
        lock.withLock { $0 = Samples() }
    }

    public struct Report: Sendable, Equatable {
        public var count = 0
        public var p50 = 0.0
        public var p95 = 0.0
        public var max = 0.0
        /// Frames that blew the 8.3 ms budget (interactive only).
        public var overBudget = 0
    }

    public func report(_ kind: Kind, budgetMS: Double) -> Report {
        let samples = lock.withLock { kind == .interactive ? $0.interactive : $0.settle }
        guard !samples.isEmpty else { return Report() }
        let sorted = samples.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }
        return Report(count: sorted.count,
                      p50: pct(0.50),
                      p95: pct(0.95),
                      max: sorted.last ?? 0,
                      overBudget: samples.filter { $0 > budgetMS }.count)
    }
}
