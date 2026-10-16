import XCTest
@testable import NotchCore

/// Entirely synthetic fixtures. These tests never instantiate MusicAppReader,
/// send an Apple Event, read a Music library, or request Automation permission.
final class MusicPlaybackTests: XCTestCase {
    private func track(title: String = "Synthetic Aurora", artist: String = "Fixture Artist",
                       album: String = "Fixture Album", duration: Double = 180,
                       persistentID: String? = "0123456789ABCDEF") -> MusicTrackIdentity? {
        MusicTrackIdentity(title: title, artist: artist, album: album,
                           duration: duration, persistentID: persistentID)
    }

    private func fields(title: String? = "Synthetic Aurora", artist: String? = "Fixture Artist",
                        album: String? = "Fixture Album", duration: Double? = 180,
                        persistentID: String? = "0123456789ABCDEF") -> MusicTrackFields {
        MusicTrackFields(title: title, artist: artist, album: album,
                         duration: duration, persistentID: persistentID)
    }

    private func result(before: MusicTrackFields? = nil, after: MusicTrackFields? = nil,
                        stateBefore: MusicPlaybackState = .playing, stateAfter: MusicPlaybackState = .playing,
                        position: Double? = 20, observedAt: Double = 100) -> MusicReadResult {
        MusicPlaybackValidation.result(before: before ?? fields(), after: after ?? fields(),
                                       stateBefore: stateBefore, stateAfter: stateAfter,
                                       position: position, observedAt: observedAt)
    }

    func testValidSnapshotPreservesMetadataAndMonotonicObservation() throws {
        guard case .snapshot(let snapshot) = result() else { return XCTFail("Expected a synthetic snapshot") }
        XCTAssertEqual(snapshot.track, track())
        XCTAssertEqual(snapshot.position, 20)
        XCTAssertEqual(snapshot.observedAt, 100)
        XCTAssertEqual(snapshot.state, .playing)
    }

    func testStableComparisonIncludesEveryIdentityField() {
        XCTAssertEqual(track(), track())
        XCTAssertNotEqual(track(), track(title: "Synthetic Dusk"))
        XCTAssertNotEqual(track(), track(artist: "Another Fixture"))
        XCTAssertNotEqual(track(), track(album: "Another Album"))
        XCTAssertNotEqual(track(), track(duration: 181))
        XCTAssertNotEqual(track(), track(persistentID: "0123456789ABCDE0"))
        XCTAssertNotEqual(track(), track(persistentID: nil))
        XCTAssertEqual(track(persistentID: nil), track(persistentID: nil))
    }

    func testUnicodeNormalizationAndPersistentIDCaseAreStable() {
        XCTAssertEqual(track(title: "  Cafe\u{301} 星  ", persistentID: "0123456789abcdef"),
                       track(title: "Café 星", persistentID: "0123456789ABCDEF"))
        XCTAssertNotEqual(track(title: "Synthetic Aurora"), track(title: "synthetic aurora"))
        XCTAssertNotNil(track(artist: "", album: "", persistentID: nil))
    }

    func testTitleAndTextBoundsFailClosed() {
        XCTAssertNil(track(title: ""))
        XCTAssertNil(track(title: "   "))
        XCTAssertNil(track(title: "Synthetic\u{0}Title"))
        XCTAssertNil(track(artist: "Fixture\nArtist"))
        XCTAssertNil(track(album: String(repeating: "x", count: 4_097)))
        XCTAssertNil(track(title: String(repeating: "星", count: 1_366)))
        XCTAssertNotNil(track(title: String(repeating: "x", count: 4_096)))
    }

    func testDurationAndPersistentIDBounds() {
        for duration in [Double.nan, .infinity, -.infinity, -1, 0, 86_401] {
            XCTAssertNil(track(duration: duration))
        }
        XCTAssertNotNil(track(duration: 86_400))
        XCTAssertNil(track(persistentID: "not-a-library-id"))
        XCTAssertNil(track(persistentID: String(repeating: "F", count: 17)))
        XCTAssertNil(track(persistentID: "0123456789ABCDEG"))
        XCTAssertEqual(track(persistentID: ""), track(persistentID: nil))
    }

    func testPositionAndObservationMustBeFiniteAndInRange() throws {
        let identity = try XCTUnwrap(track())
        for position in [Double.nan, .infinity, -.infinity, -0.01, 180.01] {
            XCTAssertNil(MusicPlaybackSnapshot(track: identity, state: .playing, position: position, observedAt: 100))
        }
        for timestamp in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertNil(MusicPlaybackSnapshot(track: identity, state: .playing, position: 20, observedAt: timestamp))
        }
        XCTAssertNotNil(MusicPlaybackSnapshot(track: identity, state: .stopped, position: 0, observedAt: 0))
        XCTAssertNotNil(MusicPlaybackSnapshot(track: identity, state: .paused, position: 180, observedAt: 100))
    }

    func testMissingPropertiesAndBlankTitleAreUnknownInsteadOfOldTrack() {
        for missing in [fields(title: nil), fields(artist: nil), fields(album: nil),
                        fields(duration: nil), fields(title: " ")] {
            XCTAssertEqual(result(before: missing), .unavailable(.unknownTrack))
            XCTAssertEqual(result(after: missing), .unavailable(.unknownTrack))
        }
        XCTAssertEqual(result(position: nil), .unavailable(.unknownTrack))
    }

    func testMalformedPropertiesAreInvalidInsteadOfZeros() {
        for malformed in [fields(title: "Bad\u{0}Title"), fields(duration: .nan),
                          fields(duration: -1), fields(persistentID: "bad")] {
            XCTAssertEqual(result(before: malformed), .unavailable(.invalidResponse))
        }
        XCTAssertEqual(result(position: .nan), .unavailable(.invalidResponse))
        XCTAssertEqual(result(position: -1), .unavailable(.invalidResponse))
        XCTAssertEqual(result(observedAt: .infinity), .unavailable(.invalidResponse))
    }

    func testMetadataAndStateChangeDuringReadRejectWholeSample() {
        for changed in [fields(title: "Synthetic Dusk"), fields(artist: "Changed Artist"),
                        fields(album: "Changed Album"), fields(duration: 181),
                        fields(persistentID: nil), fields(persistentID: "FEDCBA9876543210")] {
            XCTAssertEqual(result(after: changed), .unavailable(.changedDuringRead))
        }
        XCTAssertEqual(result(stateAfter: .paused), .unavailable(.changedDuringRead))
        XCTAssertEqual(result(stateAfter: .unknown), .unavailable(.changedDuringRead))
    }

    func testUnknownAndStoppedStatesAreExplicitAndNeverAssumedPlaying() {
        let states: [MusicPlaybackState] = [.paused, .stopped, .unknown]
        for state in states {
            guard case .snapshot(let sample) = result(stateBefore: state, stateAfter: state) else {
                return XCTFail("Expected state-preserving synthetic snapshot")
            }
            XCTAssertEqual(sample.state, state)
        }
    }

    func testAppleEventErrorsUseOnlyFiniteCategoriesAndNumericCodes() {
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-600), .notRunning)
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-609), .notRunning)
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-1743), .permissionDenied)
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-1744), .authorizationRequired)
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-1712), .timedOut)
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-1728), .unknownTrack)
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-128), .cancelled)
        XCTAssertEqual(MusicReadFailure.appleEventStatus(-1708), .appleEvent(-1708))
    }

    func testAdapterConstructionIsInertAndOrdinaryReadCannotPrompt() async {
        let probe = MusicReadProbe()
        let provider = BoundedMusicSnapshotProvider { request in
            probe.record(prompt: request.allowPermissionPrompt)
            return .unavailable(.authorizationRequired)
        }
        XCTAssertEqual(probe.prompts, [])
        let value = await provider.read()
        XCTAssertEqual(value, .unavailable(.authorizationRequired))
        XCTAssertEqual(probe.prompts, [false])
    }

    func testExplicitPermissionActionReachesOnlyThatRead() async throws {
        let probe = MusicReadProbe()
        let provider = BoundedMusicSnapshotProvider { request in
            probe.record(prompt: request.allowPermissionPrompt)
            return .unavailable(.permissionDenied)
        }
        let first = await provider.read(allowPermissionPrompt: true)
        XCTAssertEqual(first, .unavailable(.permissionDenied))
        // A completion can resume its consumer just before releasing the worker
        // slot. Busy is a valid bounded backpressure response, never a queued read.
        var second = await provider.read()
        for _ in 0..<100 where second == .unavailable(.busy) {
            try await Task.sleep(nanoseconds: 1_000_000)
            second = await provider.read()
        }
        XCTAssertEqual(second, .unavailable(.permissionDenied))
        XCTAssertEqual(probe.prompts, [true, false])
    }

    func testTransportFixturesPreserveAbsentDeniedUnknownAndErrors() async {
        let failures: [MusicReadFailure] = [.notRunning, .permissionDenied, .authorizationRequired,
                                          .unknownTrack, .targetMismatch, .invalidResponse, .appleEvent(-1708)]
        for failure in failures {
            let provider = BoundedMusicSnapshotProvider { _ in .unavailable(failure) }
            let value = await provider.read()
            XCTAssertEqual(value, .unavailable(failure))
        }
    }

    func testTimeoutReturnsWithoutWaitingAndDoesNotQueueAnotherIPC() async {
        let began = expectation(description: "Synthetic transport began")
        let release = DispatchSemaphore(value: 0)
        let probe = MusicReadProbe()
        let provider = BoundedMusicSnapshotProvider(timeout: 0.1) { request in
            probe.record(prompt: request.allowPermissionPrompt)
            began.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return .unavailable(.unknownTrack) // Deliberately late; must be dropped.
        }
        defer { release.signal() }
        let pending = Task { await provider.read() }
        await fulfillment(of: [began], timeout: 2)
        let value = await pending.value
        XCTAssertEqual(value, .unavailable(.timedOut))
        let overlapping = await provider.read(allowPermissionPrompt: true)
        XCTAssertEqual(overlapping, .unavailable(.busy))
        XCTAssertEqual(probe.prompts, [false])
    }

    func testCancellationRetiresLateSnapshotAndKeepsSingleWorkerSlot() async throws {
        let began = expectation(description: "Synthetic transport began")
        let finished = expectation(description: "Synthetic transport returned")
        let release = DispatchSemaphore(value: 0)
        let identity = try XCTUnwrap(track())
        let sample = try XCTUnwrap(MusicPlaybackSnapshot(track: identity, state: .playing, position: 20, observedAt: 100))
        let probe = MusicReadProbe()
        let provider = BoundedMusicSnapshotProvider { request in
            probe.record(prompt: request.allowPermissionPrompt)
            began.fulfill()
            _ = release.wait(timeout: .now() + 3)
            do {
                try request.checkCancellation()
                XCTFail("Cancelled transport must reject its retired request")
            } catch {
                XCTAssertEqual(error as? MusicReadFailure, .cancelled)
            }
            finished.fulfill()
            return .snapshot(sample)
        }
        defer { release.signal() }
        let pending = Task { await provider.read() }
        await fulfillment(of: [began], timeout: 2)
        pending.cancel()
        let value = await pending.value
        XCTAssertEqual(value, .unavailable(.cancelled))
        let overlapping = await provider.read()
        XCTAssertEqual(overlapping, .unavailable(.busy))
        XCTAssertEqual(probe.prompts, [false])
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
        let stillCancelled = await pending.value
        XCTAssertEqual(stillCancelled, .unavailable(.cancelled))
    }

    func testPrecancelledCallerNeverStartsTransport() async {
        let probe = MusicReadProbe()
        let provider = BoundedMusicSnapshotProvider { request in
            probe.record(prompt: request.allowPermissionPrompt)
            return .unavailable(.unknownTrack)
        }
        let pending = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return await provider.read(allowPermissionPrompt: true)
        }
        pending.cancel()
        let value = await pending.value
        XCTAssertEqual(value, .unavailable(.cancelled))
        XCTAssertEqual(probe.prompts, [])
    }
}

private final class MusicReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPrompts: [Bool] = []
    var prompts: [Bool] { lock.lock(); defer { lock.unlock() }; return storedPrompts }
    func record(prompt: Bool) { lock.lock(); storedPrompts.append(prompt); lock.unlock() }
}
