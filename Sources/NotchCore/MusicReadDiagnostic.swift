import Foundation

/// A single in-memory status, never song names, event payloads, or a trace log.
public struct MusicReadDiagnostic: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, target, permission, stateBefore, trackBefore, position, trackAfter, stateAfter, validation
    }
    public let phase: Phase
    public let elapsed: TimeInterval
    public let failure: MusicReadFailure?
}

public final class MusicReadDiagnosticStore: @unchecked Sendable {
    private let lock = NSLock()
    private var phase: MusicReadDiagnostic.Phase = .idle
    private var started: TimeInterval?
    private var ended: TimeInterval?
    private var failure: MusicReadFailure?

    public init() {}

    public func begin() {
        lock.lock(); defer { lock.unlock() }
        started = ProcessInfo.processInfo.systemUptime; ended = nil; failure = nil; phase = .target
    }

    public func mark(_ phase: MusicReadDiagnostic.Phase) {
        lock.lock(); defer { lock.unlock() }
        guard ended == nil else { return }
        self.phase = phase
    }

    public func finish(_ result: MusicReadResult) {
        lock.lock(); defer { lock.unlock() }
        guard ended == nil else { return }
        ended = ProcessInfo.processInfo.systemUptime
        if case .unavailable(let failure) = result { self.failure = failure }
    }

    public var snapshot: MusicReadDiagnostic {
        lock.lock(); defer { lock.unlock() }
        return MusicReadDiagnostic(phase: phase,
                                   elapsed: started.map { max(0, (ended ?? ProcessInfo.processInfo.systemUptime) - $0) } ?? 0,
                                   failure: failure)
    }
}
