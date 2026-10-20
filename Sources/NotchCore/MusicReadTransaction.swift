import Foundation

/// The production adapter's synchronous transaction algorithm with injectable
/// transport/decoder boundaries. Public Apple Events and ImageIO remain in the
/// macOS adapter; tests exercise this same ordering without Music or TCC.
public struct MusicReadTransaction {
    private let state: () throws -> MusicPlaybackState
    private let track: () throws -> MusicTrackFields
    private let position: () throws -> TimeInterval?
    private let validate: () throws -> Void

    public init(state: @escaping () throws -> MusicPlaybackState,
                track: @escaping () throws -> MusicTrackFields,
                position: @escaping () throws -> TimeInterval?,
                validate: @escaping () throws -> Void) {
        self.state = state; self.track = track; self.position = position; self.validate = validate
    }

    public func playback(request: MusicReadRequest,
                         diagnostic: MusicReadDiagnosticStore? = nil) throws -> MusicReadResult {
        try request.checkCancellation()
        diagnostic?.mark(.stateBefore)
        let beforeState = try state()
        diagnostic?.mark(.trackBefore)
        let before = try track()
        diagnostic?.mark(.position)
        let observedAt = ProcessInfo.processInfo.systemUptime
        let observedPosition = try position()
        diagnostic?.mark(.trackAfter)
        let after = try track()
        diagnostic?.mark(.stateAfter)
        let afterState = try state()
        try request.checkCancellation()
        diagnostic?.mark(.validation)
        try validate()
        return MusicPlaybackValidation.result(before: before, after: after,
                                               stateBefore: beforeState, stateAfter: afterState,
                                               position: observedPosition, observedAt: observedAt)
    }

    public func artwork(for expectedTrack: MusicTrackIdentity, request: MusicReadRequest,
                        read: () throws -> Data?, decode: (Data) -> MusicArtwork?) throws -> MusicArtwork? {
        try request.checkCancellation()
        let beforeState = try state()
        let before = try track()
        let initial = MusicPlaybackValidation.result(before: before, after: before,
                                                      stateBefore: beforeState, stateAfter: beforeState,
                                                      position: 0, observedAt: 0)
        guard case .snapshot(let initialSnapshot) = initial,
              initialSnapshot.state == .playing, initialSnapshot.track == expectedTrack else {
            throw MusicReadFailure.changedDuringRead
        }
        let bytes = try read()
        try request.checkCancellation()
        let artwork = bytes.flatMap(decode)
        try request.checkCancellation()
        let after = try track()
        let afterState = try state()
        try request.checkCancellation()
        try validate()
        let result = MusicPlaybackValidation.result(before: before, after: after,
                                                     stateBefore: beforeState, stateAfter: afterState,
                                                     position: 0, observedAt: 0)
        guard case .snapshot(let snapshot) = result,
              snapshot.state == .playing, snapshot.track == expectedTrack else {
            throw MusicReadFailure.changedDuringRead
        }
        return artwork
    }
}
