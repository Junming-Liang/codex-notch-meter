import Foundation

/// Drains the final SwiftUI update after an animated close reaches exact zero.
/// This acknowledges view-update state only, never a GPU commit or scanout.
public struct ClosePresentationDrain: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case idle, pending, ready, timedOut
    }

    public let timeout: TimeInterval
    public private(set) var generation: UInt64 = 0
    public private(set) var startedAt: TimeInterval?
    public var isPending: Bool { startedAt != nil }
    private var latestTime: TimeInterval?
    private var latestRenderedAt: TimeInterval?

    /// A caller may shorten the deadline. Its next available valid main-loop poll
    /// at or after it must retire the source; a blocked main thread can deliver late.
    /// Invalid durations use the 120ms deadline, not a wall-clock scheduling guarantee.
    public init(timeout: TimeInterval = 0.12) {
        self.timeout = timeout.isFinite && timeout > 0 ? min(0.12, timeout) : 0.12
    }

    /// Call on the terminal motion step, before requesting its final view update.
    /// Initial idle, opening, Reduce Motion and nonterminal steps do not start a drain.
    /// Capture the returned generation for observations belonging to this close.
    @discardableResult
    public mutating func begin(previousProgress: Double, progress: Double, expanded: Bool,
                               reduceMotion: Bool, now: TimeInterval) -> UInt64? {
        guard !expanded, !reduceMotion, previousProgress.isFinite,
              previousProgress > 0, previousProgress <= 1, progress == 0,
              now.isFinite, now >= 0, latestTime.map({ now > $0 }) ?? true else { return nil }
        generation &+= 1
        startedAt = now
        latestTime = now
        latestRenderedAt = nil
        return generation
    }

    /// Poll on a later normal-run-loop turn using one monotonic clock for all times.
    /// viewportMatches must include both the rendered viewport and native frame
    /// matching the expected collapsed geometry. A fresh zero-progress view update
    /// must be observed before the deadline; timeout is explicit, not success.
    /// Ready and timeout each clear the drain, so the caller can retire its source
    /// once. Invalid or retired-generation observations cannot acknowledge a close.
    public mutating func poll(generation: UInt64, now: TimeInterval, renderedAt: TimeInterval,
                              renderedProgress: Double, viewportMatches: Bool) -> Outcome {
        guard let start = startedAt else { return .idle }
        guard generation == self.generation else { return .pending }
        guard now.isFinite, now > (latestTime ?? start) else { return .pending }
        latestTime = now
        // At the exact deadline cleanup wins, even if a late acknowledgment arrives.
        if now >= start + timeout { cancel(); return .timedOut }
        guard renderedAt.isFinite, renderedAt >= start, renderedAt <= now,
              latestRenderedAt.map({ renderedAt > $0 }) ?? true else { return .pending }
        latestRenderedAt = renderedAt
        guard renderedProgress == 0, viewportMatches else { return .pending }
        cancel()
        return .ready
    }

    /// Reentry, Reduce Motion changes and teardown abandon pending presentation.
    /// Keep the generation and clock watermark, so stale work cannot revive it.
    public mutating func cancel() {
        startedAt = nil
        latestRenderedAt = nil
    }
}
