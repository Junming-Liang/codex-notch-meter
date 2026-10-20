import Foundation

/// Process lifetime and the complete validated track, never a catalog lookup.
public struct MusicArtworkKey: Equatable, Sendable {
    public let pid: Int32
    public let launchDate: Date
    public let track: MusicTrackIdentity

    public init(pid: Int32, launchDate: Date, track: MusicTrackIdentity) {
        self.pid = pid; self.launchDate = launchDate; self.track = track
    }
}

/// Optional work owns a separate single worker. A stuck decoder retains only
/// this slot, never the required playback slot. No queued backlog or disk cache.
public final class MusicArtworkCache: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.codexnotchmeter.music-artwork", qos: .utility)
    private var key: MusicArtworkKey?
    private var generation: UInt64 = 0
    private var session: UInt64 = 0
    private var lastDiagnostic = MusicArtworkDiagnostic(phase: .idle, elapsed: 0, failure: nil)
    private var occupied = false
    private var attempted = false
    private var artwork: MusicArtwork?
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 2) {
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 2) : 2
    }

    var hasActiveWorker: Bool {
        lock.lock(); defer { lock.unlock() }; return occupied
    }

    public var sessionToken: UInt64 {
        lock.lock(); defer { lock.unlock() }; return session
    }

    public var diagnostic: MusicArtworkDiagnostic {
        lock.lock(); defer { lock.unlock() }; return lastDiagnostic
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        session &+= 1
        lastDiagnostic = MusicArtworkDiagnostic(phase: .idle, elapsed: 0, failure: nil)
        key = nil; artwork = nil; attempted = false
    }

    /// Returns immediately. The operation must bracket its own optional read
    /// against this key and revalidate permission without ever prompting.
    public func cachedArtwork(for newKey: MusicArtworkKey, session expectedSession: UInt64,
                              operation: @escaping @Sendable (MusicReadRequest) throws -> MusicArtwork?) -> MusicArtwork? {
        lock.lock()
        guard session == expectedSession else { lock.unlock(); return nil }
        if key != newKey {
            generation &+= 1
            key = newKey; artwork = nil; attempted = false
            lastDiagnostic = MusicArtworkDiagnostic(phase: .idle, elapsed: 0, failure: nil)
        }
        let cached = artwork
        guard !occupied, !attempted else { lock.unlock(); return cached }
        occupied = true; attempted = true
        lastDiagnostic = MusicArtworkDiagnostic(phase: .reading, elapsed: 0, failure: nil)
        let token = generation
        lock.unlock()
        queue.async { [self] in
            let started = ProcessInfo.processInfo.systemUptime
            let request = MusicReadRequest(allowPermissionPrompt: false,
                                           deadline: ProcessInfo.processInfo.systemUptime + timeout,
                                           active: { self.isCurrent(token) })
            var value: MusicArtwork?
            var failure: MusicReadFailure?
            do {
                try request.checkCancellation()
                value = try operation(request)
                try request.checkCancellation()
            } catch let error as MusicReadFailure { value = nil; failure = error }
            catch { value = nil; failure = .invalidResponse }
            lock.lock()
            if generation == token {
                artwork = value
                lastDiagnostic = MusicArtworkDiagnostic(phase: value == nil ? .unavailable : .available,
                                                        elapsed: ProcessInfo.processInfo.systemUptime - started,
                                                        failure: failure)
            }
            occupied = false
            lock.unlock()
        }
        return cached
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }
}

/// One bounded in-memory diagnostic, without track fields or a history log.
public struct MusicArtworkDiagnostic: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, reading, available, unavailable }
    public let phase: Phase
    public let elapsed: TimeInterval
    public let failure: MusicReadFailure?
}
