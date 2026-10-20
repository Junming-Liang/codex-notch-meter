import Foundation

public enum MusicPlaybackState: Equatable, Sendable {
    case playing, paused, stopped, unknown
}

/// A tiny, already-decoded sRGB thumbnail. Rows are tightly packed RGBA8 with
/// premultiplied alpha last and byte-order 32 big. This value contains no file
/// path, URL or compressed image: a consumer must construct its CGImage directly
/// from these pixels instead of invoking another image decoder. Never persist it.
public struct MusicArtwork: Equatable, Sendable {
    public static let maximumDimension = 64
    public static let bytesPerPixel = 4
    public static let maximumBytes = maximumDimension * maximumDimension * bytesPerPixel
    public let rgbaBytes: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public var bytesPerRow: Int { pixelWidth * Self.bytesPerPixel }

    public init?(rgbaBytes: Data, pixelWidth: Int, pixelHeight: Int) {
        // Validate dimensions before multiplication, including hostile Int.max.
        guard (1...Self.maximumDimension).contains(pixelWidth),
              (1...Self.maximumDimension).contains(pixelHeight),
              rgbaBytes.count == pixelWidth * pixelHeight * Self.bytesPerPixel else { return nil }
        self.rgbaBytes = rgbaBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Shared pure bounds for the public adapter's ImageIO preflight. Only one
/// JPEG/PNG frame is considered; source dimensions are checked before decoding.
public enum MusicArtworkDecodingPolicy {
    public static let maximumEncodedBytes = 4_194_304
    public static let maximumSourceDimension = 4_096
    public static let maximumSourcePixels = 16_777_216

    public static func acceptsEncodedByteCount(_ count: Int) -> Bool {
        (1...maximumEncodedBytes).contains(count)
    }

    public static func acceptsSource(pixelWidth: Double, pixelHeight: Double,
                                     imageCount: Int) -> Bool {
        guard imageCount == 1, pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth >= 1, pixelHeight >= 1,
              pixelWidth <= Double(maximumSourceDimension),
              pixelHeight <= Double(maximumSourceDimension),
              pixelWidth.rounded(.down) == pixelWidth,
              pixelHeight.rounded(.down) == pixelHeight else { return false }
        return pixelWidth * pixelHeight <= Double(maximumSourcePixels)
    }
}

/// An in-memory comparison key, not an Apple catalog identifier. Metadata alone
/// cannot distinguish two recordings with identical fields. Do not log this key.
public struct MusicTrackIdentity: Equatable, Hashable, Sendable {
    public static let maximumFieldBytes = 4_096
    public static let maximumDuration: TimeInterval = 86_400
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let persistentID: String?

    public init?(title: String, artist: String, album: String, duration: TimeInterval,
                 persistentID: String? = nil) {
        guard let title = Self.text(title), !title.isEmpty,
              let artist = Self.text(artist), let album = Self.text(album),
              duration.isFinite, duration > 0, duration <= Self.maximumDuration else { return nil }
        var identifier: String?
        if let persistentID, !persistentID.isEmpty {
            // Music's documented persistent ID is a 64-bit hexadecimal string.
            guard persistentID.utf8.count == 16,
                  persistentID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
            identifier = persistentID.uppercased()
        }
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.persistentID = identifier
    }

    private static func text(_ value: String) -> String? {
        guard value.utf8.prefix(maximumFieldBytes + 1).count <= maximumFieldBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= maximumFieldBytes else { return nil }
        return normalized
    }
}

public struct MusicPlaybackSnapshot: Equatable, Sendable {
    public let track: MusicTrackIdentity
    public let state: MusicPlaybackState
    public let position: TimeInterval
    /// Earliest monotonic time at which the position could have been observed;
    /// all consumers must use ProcessInfo.systemUptime, never wall-clock Date.
    public let observedAt: TimeInterval
    /// Optional pixels from a separately bracketed read of this exact process/track,
    /// never a prior song. Attaching cached pixels must not refresh observedAt.
    public let artwork: MusicArtwork?

    public init?(track: MusicTrackIdentity, state: MusicPlaybackState,
                 position: TimeInterval, observedAt: TimeInterval,
                 artwork: MusicArtwork? = nil) {
        guard position.isFinite, position >= 0, position <= track.duration,
              observedAt.isFinite, observedAt >= 0 else { return nil }
        self.track = track
        self.state = state
        self.position = position
        self.observedAt = observedAt
        self.artwork = artwork
    }
}

/// Finite categories only: never propagate Music's error text, which can contain
/// song names, paths or other private library information.
public enum MusicReadFailure: Error, Equatable, Sendable {
    case notRunning, authorizationRequired, permissionDenied, unknownTrack
    case changedDuringRead, timedOut, cancelled, busy, invalidResponse, targetMismatch
    case appleEvent(Int32)

    public static func appleEventStatus(_ status: Int32) -> MusicReadFailure {
        switch status {
        case -600, -609: return .notRunning
        case -1744: return .authorizationRequired
        case -1743: return .permissionDenied
        case -1712: return .timedOut
        case -128, -1711: return .cancelled
        case -1728: return .unknownTrack
        default: return .appleEvent(status)
        }
    }
}

public enum MusicReadResult: Equatable, Sendable {
    case snapshot(MusicPlaybackSnapshot)
    case unavailable(MusicReadFailure)
}

public protocol MusicSnapshotProvider: Sendable {
    /// Only a current, explicit user enable/retry action may pass true.
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult
    /// Clear optional work when monitoring is disabled or stopped.
    func invalidate()
}

public extension MusicSnapshotProvider {
    func invalidate() {}
    func read() async -> MusicReadResult { await read(allowPermissionPrompt: false) }
}

/// Untrusted transport fields. Nil means absent, not an invitation to reuse the
/// previous song. Empty artist/album strings are valid; a missing title is not.
public struct MusicTrackFields: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?
    public let persistentID: String?

    public init(title: String?, artist: String?, album: String?, duration: TimeInterval?,
                persistentID: String? = nil) {
        self.title = title; self.artist = artist; self.album = album
        self.duration = duration; self.persistentID = persistentID
    }

    fileprivate func validated() throws -> MusicTrackIdentity {
        guard let title, let artist, let album, let duration,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MusicReadFailure.unknownTrack
        }
        guard let identity = MusicTrackIdentity(title: title, artist: artist, album: album,
                                               duration: duration, persistentID: persistentID) else {
            throw MusicReadFailure.invalidResponse
        }
        return identity
    }
}

public enum MusicPlaybackValidation {
    /// Bracket the position and optional artwork with two metadata/state reads. This rejects a
    /// detected transition, but cannot prove Music's current-track data is fresh
    /// or make several Apple Events atomic (including an A -> B -> A transition).
    public static func result(before: MusicTrackFields, after: MusicTrackFields,
                              stateBefore: MusicPlaybackState, stateAfter: MusicPlaybackState,
                              position: TimeInterval?, observedAt: TimeInterval,
                              artwork: MusicArtwork? = nil) -> MusicReadResult {
        do {
            let first = try before.validated()
            let last = try after.validated()
            guard first == last, stateBefore == stateAfter else { return .unavailable(.changedDuringRead) }
            guard let position else { return .unavailable(.unknownTrack) }
            guard let snapshot = MusicPlaybackSnapshot(track: last, state: stateAfter,
                                                        position: position, observedAt: observedAt,
                                                        artwork: artwork) else {
                return .unavailable(.invalidResponse)
            }
            return .snapshot(snapshot)
        } catch let failure as MusicReadFailure { return .unavailable(failure) }
        catch { return .unavailable(.invalidResponse) }
    }
}

/// Injected synchronous transport boundary. The transport checks cancellation
/// and remainingTime before every IPC and gives each IPC that remaining budget.
public struct MusicReadRequest: Sendable {
    public let allowPermissionPrompt: Bool
    public let deadline: TimeInterval
    private let active: @Sendable () -> Bool

    init(allowPermissionPrompt: Bool, deadline: TimeInterval,
                     active: @escaping @Sendable () -> Bool) {
        self.allowPermissionPrompt = allowPermissionPrompt
        self.deadline = deadline
        self.active = active
    }

    public var remainingTime: TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }

    public func checkCancellation() throws {
        guard active() else { throw MusicReadFailure.cancelled }
        guard remainingTime > 0 else { throw MusicReadFailure.timedOut }
    }
}

/// At most one underlying synchronous operation, including after caller timeout
/// or cancellation. A stuck OS prompt occupies that one slot; it never queues an
/// unbounded series of worker tasks. Cancellation does not dismiss system UI.
public final class BoundedMusicSnapshotProvider: MusicSnapshotProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.codexnotchmeter.music-read", qos: .utility)
    private let lock = NSLock()
    private var occupied = false
    private let timeout: TimeInterval
    private let authorizationTimeout: TimeInterval
    private let operation: @Sendable (MusicReadRequest) -> MusicReadResult

    public init(timeout: TimeInterval = 2, authorizationTimeout: TimeInterval = 30,
                operation: @escaping @Sendable (MusicReadRequest) -> MusicReadResult) {
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 5) : 2
        self.authorizationTimeout = authorizationTimeout.isFinite && authorizationTimeout > 0
            ? min(authorizationTimeout, 60) : 30
        self.operation = operation
    }

    public func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        guard claimWorker() else { return .unavailable(.busy) }
        let gate = MusicReadGate()
        let budget = allowPermissionPrompt ? authorizationTimeout : timeout
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let timer = DispatchWorkItem { [weak gate] in gate?.finish(.unavailable(.timedOut)) }
                gate.installTimer(timer)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget, execute: timer)
                queue.async { [self] in
                    defer { releaseWorker() }
                    guard gate.isPending else { return }
                    let request = MusicReadRequest(allowPermissionPrompt: allowPermissionPrompt,
                                                   deadline: deadline, active: { gate.isPending })
                    let result = operation(request)
                    // Never deliver a result observed after the deadline even if
                    // the timer queue was temporarily delayed by system load.
                    gate.finish(request.remainingTime > 0 ? result : .unavailable(.timedOut))
                }
            }
        } onCancel: { gate.finish(.unavailable(.cancelled)) }
    }

    private func claimWorker() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !occupied else { return false }
        occupied = true
        return true
    }

    private func releaseWorker() {
        lock.lock(); occupied = false; lock.unlock()
    }
}

private final class MusicReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: MusicReadResult?
    private var continuation: CheckedContinuation<MusicReadResult, Never>?
    private var timer: DispatchWorkItem?

    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }

    func install(_ continuation: CheckedContinuation<MusicReadResult, Never>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(returning: result); return }
        self.continuation = continuation
        lock.unlock()
    }

    func installTimer(_ timer: DispatchWorkItem) {
        lock.lock()
        if result != nil { lock.unlock(); timer.cancel(); return }
        self.timer = timer
        lock.unlock()
    }

    func finish(_ value: MusicReadResult) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation; self.continuation = nil
        let timer = self.timer; self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}
