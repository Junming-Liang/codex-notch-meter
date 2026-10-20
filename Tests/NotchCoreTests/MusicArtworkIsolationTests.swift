import XCTest
@testable import NotchCore

final class MusicArtworkIsolationTests: XCTestCase {
    private func identity(_ title: String = "Fixture A") -> MusicTrackIdentity {
        MusicTrackIdentity(title: title, artist: "Fixture", album: "Fixture", duration: 120)!
    }
    private func fields(_ title: String = "Fixture A") -> MusicTrackFields {
        MusicTrackFields(title: title, artist: "Fixture", album: "Fixture", duration: 120)
    }
    private func key(_ title: String = "Fixture A", launch: Double = 1) -> MusicArtworkKey {
        MusicArtworkKey(pid: 123, launchDate: Date(timeIntervalSince1970: launch), track: identity(title))
    }
    private func pixels() -> MusicArtwork {
        MusicArtwork(rgbaBytes: Data([255, 0, 0, 255]), pixelWidth: 1, pixelHeight: 1)!
    }
    private func request() -> MusicReadRequest {
        MusicReadRequest(allowPermissionPrompt: false,
                         deadline: ProcessInfo.processInfo.systemUptime + 2, active: { true })
    }
    private func transaction() -> MusicReadTransaction {
        MusicReadTransaction(state: { .playing }, track: { self.fields() },
                             position: { 10 }, validate: {})
    }
    private func waitForCompletion(_ cache: MusicArtworkCache) async {
        for _ in 0..<200 {
            if !cache.hasActiveWorker { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Optional worker did not finish")
    }

    func testSlowOptionalDecoderCannotTimeoutOrBusyRequiredPlayback() async throws {
        try await assertSlowOptionalDoesNotBlock(stallInDecoder: true)
    }

    func testSlowOptionalIPCCannotTimeoutOrBusyRequiredPlayback() async throws {
        try await assertSlowOptionalDoesNotBlock(stallInDecoder: false)
    }

    private func assertSlowOptionalDoesNotBlock(stallInDecoder: Bool) async throws {
        let cache = MusicArtworkCache()
        let started = expectation(description: "Optional decoder entered")
        let release = DispatchSemaphore(value: 0)
        let art = pixels()
        let key = key()
        let fixture = fields()
        XCTAssertNil(cache.cachedArtwork(for: key, session: cache.sessionToken) { request in
            let transport = MusicReadTransaction(state: { .playing }, track: { fixture },
                                                  position: { 10 }, validate: {})
            return try transport.artwork(for: key.track, request: request, read: {
                if !stallInDecoder {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return Data([1])
            }) { _ in
                if stallInDecoder {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return art
            }
        })
        await fulfillment(of: [started], timeout: 1)
        let required = BoundedMusicSnapshotProvider { request in
            do {
                return try MusicReadTransaction(state: { .playing }, track: { fixture },
                                                position: { 10 }, validate: {}).playback(request: request)
            } catch { return .unavailable(.invalidResponse) }
        }
        // The decoder is still stuck beyond the unchanged 2-second read budget.
        try await Task.sleep(nanoseconds: 2_100_000_000)
        for _ in 0..<3 {
            guard case .snapshot(let snapshot) = await required.read() else {
                release.signal(); return XCTFail("Optional work blocked required playback")
            }
            XCTAssertEqual(snapshot.position, 10)
            XCTAssertNil(snapshot.artwork)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        release.signal()
        await waitForCompletion(cache)
        XCTAssertEqual(cache.diagnostic.failure, .timedOut)
        XCTAssertNil(cache.cachedArtwork(for: key, session: cache.sessionToken) { _ in art })
    }

    func testLateTrackAIsNotAttachedToTrackBOrNewProcessLifetime() async {
        let cache = MusicArtworkCache()
        let started = expectation(description: "A started")
        let release = DispatchSemaphore(value: 0)
        let art = pixels()
        XCTAssertNil(cache.cachedArtwork(for: key(), session: cache.sessionToken) { _ in
            started.fulfill(); _ = release.wait(timeout: .now() + 2); return art
        })
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNil(cache.cachedArtwork(for: key("Fixture B"), session: cache.sessionToken) { _ in
            XCTFail("Must not queue a second optional worker"); return art
        })
        release.signal()
        // Completion of A must not become B's cached artwork. A later B poll may
        // start its own job, but can only return nil on that first observation.
        await waitForCompletion(cache)
        XCTAssertNil(cache.cachedArtwork(for: key("Fixture B"), session: cache.sessionToken) { _ in art })
        await waitForCompletion(cache)
        XCTAssertEqual(cache.cachedArtwork(for: key("Fixture B"), session: cache.sessionToken) { _ in nil }, art)
        XCTAssertNil(cache.cachedArtwork(for: key("Fixture B", launch: 2), session: cache.sessionToken) { _ in nil })
    }

    func testDisableInvalidatesInFlightWorkAndOldReadSession() async {
        let cache = MusicArtworkCache()
        let oldSession = cache.sessionToken
        cache.invalidate()
        XCTAssertNil(cache.cachedArtwork(for: key(), session: oldSession) { _ in
            XCTFail("Disabled read must not start optional IPC"); return nil
        })
        XCTAssertEqual(cache.diagnostic.phase, .idle)
    }

    func testDisableCancelsAlreadyRunningArtwork() async {
        let cache = MusicArtworkCache()
        let started = expectation(description: "Artwork started")
        let cancellationChecked = expectation(description: "Cancellation observed")
        let release = DispatchSemaphore(value: 0)
        XCTAssertNil(cache.cachedArtwork(for: key(), session: cache.sessionToken) { request in
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
            XCTAssertThrowsError(try request.checkCancellation()) { error in
                XCTAssertEqual(error as? MusicReadFailure, .cancelled)
            }
            cancellationChecked.fulfill()
            return nil
        })
        await fulfillment(of: [started], timeout: 1)
        cache.invalidate()
        release.signal()
        await fulfillment(of: [cancellationChecked], timeout: 1)
        await waitForCompletion(cache)
        XCTAssertEqual(cache.diagnostic.phase, .idle)
    }

    func testProductionTransactionOrderExcludesArtworkAndRecordsFailurePhase() throws {
        var order: [String] = []
        let diagnostic = MusicReadDiagnosticStore()
        diagnostic.begin()
        let transaction = MusicReadTransaction(state: { order.append("state"); return .playing },
                                                track: { order.append("track"); return self.fields() },
                                                position: { order.append("position"); return 10 },
                                                validate: { order.append("validate") })
        _ = try transaction.playback(request: request(), diagnostic: diagnostic)
        XCTAssertEqual(order, ["state", "track", "position", "track", "state", "validate"])
        XCTAssertEqual(diagnostic.snapshot.phase, .validation)
        diagnostic.begin()
        let failed = MusicReadTransaction(state: { .playing }, track: { self.fields() },
                                           position: { throw MusicReadFailure.invalidResponse }, validate: {})
        XCTAssertThrowsError(try failed.playback(request: request(), diagnostic: diagnostic))
        diagnostic.finish(.unavailable(.invalidResponse))
        XCTAssertEqual(diagnostic.snapshot.phase, .position)
        XCTAssertEqual(diagnostic.snapshot.failure, .invalidResponse)
        diagnostic.mark(.validation)
        XCTAssertEqual(diagnostic.snapshot.phase, .position)
    }

    func testOptionalPermissionFailureRemainsInBoundedDiagnostic() async {
        let cache = MusicArtworkCache()
        XCTAssertNil(cache.cachedArtwork(for: key(), session: cache.sessionToken) { _ in
            throw MusicReadFailure.permissionDenied
        })
        await waitForCompletion(cache)
        XCTAssertEqual(cache.diagnostic.failure, .permissionDenied)
        XCTAssertGreaterThanOrEqual(cache.diagnostic.elapsed, 0)
    }

    func testProductionTransactionRejectsChangedTrackAndState() throws {
        var trackReads = 0
        let trackChange = MusicReadTransaction(state: { .playing }, track: {
            trackReads += 1
            return self.fields(trackReads == 1 ? "Fixture A" : "Fixture B")
        }, position: { 10 }, validate: {})
        XCTAssertEqual(try trackChange.playback(request: request()), .unavailable(.changedDuringRead))
        var stateReads = 0
        let stateChange = MusicReadTransaction(state: {
            stateReads += 1; return stateReads == 1 ? .playing : .paused
        }, track: { self.fields() }, position: { 10 }, validate: {})
        XCTAssertThrowsError(try stateChange.artwork(for: identity(), request: request(), read: { Data([1]) },
                                                    decode: { _ in self.pixels() })) { error in
            XCTAssertEqual(error as? MusicReadFailure, .changedDuringRead)
        }
    }

    func testOptionalBracketRejectsTrackChangeAndWrongExpectedIdentity() throws {
        var reads = 0
        let changed = MusicReadTransaction(state: { .playing }, track: {
            reads += 1; return self.fields(reads == 1 ? "Fixture A" : "Fixture B")
        }, position: { 0 }, validate: {})
        XCTAssertThrowsError(try changed.artwork(for: identity(), request: request(), read: { Data([1]) },
                                                decode: { _ in self.pixels() })) { error in
            XCTAssertEqual(error as? MusicReadFailure, .changedDuringRead)
        }
        XCTAssertThrowsError(try transaction().artwork(for: identity("Fixture B"), request: request(),
                                                       read: { Data([1]) }, decode: { _ in self.pixels() }))
    }

    func testMissingPositionRemainsUnknownTrackInsteadOfZero() throws {
        let missing = MusicReadTransaction(state: { .playing }, track: { self.fields() },
                                           position: { nil }, validate: {})
        XCTAssertEqual(try missing.playback(request: request()), .unavailable(.unknownTrack))
    }

    func testProductionTransactionPreservesPermissionFailureAndObservedTime() throws {
        let denied = MusicReadTransaction(state: { throw MusicReadFailure.permissionDenied },
                                          track: { self.fields() }, position: { 10 }, validate: {})
        XCTAssertThrowsError(try denied.playback(request: request())) { error in
            XCTAssertEqual(error as? MusicReadFailure, .permissionDenied)
        }
        guard case .snapshot(let snapshot) = try transaction().playback(request: request()) else {
            return XCTFail("Expected snapshot")
        }
        let enriched = MusicPlaybackSnapshot(track: snapshot.track, state: snapshot.state,
                                             position: snapshot.position, observedAt: snapshot.observedAt,
                                             artwork: pixels())
        XCTAssertEqual(enriched?.observedAt, snapshot.observedAt)
    }
}
