import XCTest
@testable import NotchCore

/// Entirely invented fixtures; no live song data or network requests.
final class AMLLLyricsLookupTests: XCTestCase {
    private func track(album: String = "Orbit") throws -> LyricsLookupTrack {
        try LyricsLookupTrack(title: "Paper + Comet", artist: "Glass Orchard", album: album, duration: 180)
    }
    private func record(_ changes: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["id": 1, "trackName": "Paper + Comet", "artistName": "Glass Orchard",
            "albumName": "Orbit", "duration": 60, "instrumental": false,
            "syncedLyrics": "[00:01.00]Synthetic opening\n[01:00.00]Synthetic ending", "plainLyrics": "Synthetic text"]
        r.merge(changes) { _, new in new }; return r
    }
    private func decode(_ records: [[String: Any]], status: Int = 200) throws -> LyricsLookupResult {
        let t = try track(), r = try AMLLLookup.request(track: t, consent: true)
        return try AMLLLookup.decode(LyricsLookupResponse(url: r.url, statusCode: status,
            body: JSONSerialization.data(withJSONObject: records)), for: t, request: r)
    }
    func testDurationIsNotRecordingDuration() throws {
        guard case .matched = try decode([record()]) else { return XCTFail("Expected synthetic match") }
    }
    func testEmptyAndWrongIdentityAreNoMatch() throws {
        XCTAssertEqual(try decode([]), .noMatch)
        for field in ["trackName", "artistName", "albumName"] {
            XCTAssertEqual(try decode([record([field: "Different"])]), .noMatch)
        }
    }
    func testRecordingQualifiersArePreserved() throws {
        XCTAssertEqual(try decode([record(["trackName": "Paper + Comet (Live)"])]), .noMatch)
        XCTAssertEqual(try decode([record(["albumName": "Orbit (Remastered)"])]), .noMatch)
    }
    func testAmbiguousAndTruncatedResultsAreRejected() throws {
        XCTAssertThrowsError(try decode([record(), record(["id": 2])]))
        XCTAssertThrowsError(try decode(Array(repeating: record(), count: AMLLLookup.pageSize)))
    }
    func testTimingOverflowAndInstrumentalClaimsRejected() throws {
        XCTAssertThrowsError(try decode([record(["duration": 250])]))
        XCTAssertThrowsError(try decode([record(["syncedLyrics": "[04:00.00]Synthetic overflow"])]))
        XCTAssertThrowsError(try decode([record(["instrumental": true])]))
    }
    func testMetadataMismatchIsRejected() throws {
        XCTAssertThrowsError(try decode([record(["syncedLyrics": "[ar:Other]\n[00:01.00]Synthetic"])]))
    }
    func test503IsNotNoMatch() throws {
        XCTAssertThrowsError(try decode([], status: 503)) {
            XCTAssertEqual($0 as? LyricsLookupError, .serviceUnavailable(retryAfter: 60))
        }
        XCTAssertThrowsError(try decode([], status: 404)) {
            XCTAssertEqual($0 as? LyricsLookupError, .invalidResponse)
        }
    }
    func testUnavailableIsNotInstrumental() throws {
        XCTAssertEqual(try decode([record(["syncedLyrics": "", "plainLyrics": ""])]), .unavailable)
    }
    func testConsentAndAlbumRequired() throws {
        XCTAssertThrowsError(try AMLLLookup.request(track: track(), consent: false))
        XCTAssertThrowsError(try AMLLLookup.request(track: track(album: ""), consent: true))
    }
    func testEndpointHasOnlyDisclosedMetadata() throws {
        let request = try AMLLLookup.request(track: track(), consent: true)
        let p = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(p.host, "api.amll.dev")
        XCTAssertEqual(Set(p.queryItems!.map(\.name)), Set(["track_name", "artist_name", "album_name", "pageSize"]))
        XCTAssertTrue(request.url.absoluteString.contains("%2B"))
        XCTAssertFalse(LRCLIBLookup.isAllowed(url: request.url))
        XCTAssertFalse(AMLLLookup.isAllowed(url: URL(string: "https://api.amll.dev/v1/lrclib/search?q=anything")!))
    }
    func testLegacyConsentDoesNotMigrateToAMLL() {
        let values: [String: Any] = ["musicLyricsOnlineLookupEnabled": true]
        XCTAssertFalse(values[AMLLLookup.consentKey] as? Bool ?? false)
    }
    func testPrimarySuccessDoesNotCallFallback() async throws {
        let result = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
            primary: { _, _ in .matched(.instrumental) },
            fallback: { _, _ in XCTFail("Unexpected fallback"); return .noMatch })
        XCTAssertEqual(result.source, "LRCLIB 社区歌词")
    }
    func testFallbackSuccessAndSource() async throws {
        let result = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
            primary: { _, _ in .noMatch }, fallback: { _, _ in .matched(try LRCParser.parse("[00:01.00]Synthetic")) })
        XCTAssertEqual(result.source, "AMLL 社区歌词")
    }
    func testDisabledFallbackAndGlobalConsent() async throws {
        let result = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: false,
            primary: { _, _ in .noMatch }, fallback: { _, _ in XCTFail("No AMLL consent"); return .noMatch })
        XCTAssertEqual(result.result, .noMatch)
        do {
            _ = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: false, amllConsent: true,
                primary: { _, _ in XCTFail("No consent"); return .noMatch },
                fallback: { _, _ in XCTFail("No consent"); return .noMatch })
            XCTFail("Expected consent failure")
        } catch { XCTAssertEqual(error as? LyricsLookupError, .consentRequired) }
    }
    func testOutageIsNotMaskedByFallbackMiss() async throws {
        do {
            _ = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
                primary: { _, _ in throw LyricsLookupError.serviceUnavailable(retryAfter: 90) },
                fallback: { _, _ in .noMatch })
            XCTFail("Expected original failure")
        } catch { XCTAssertEqual(error as? LyricsLookupError, .serviceUnavailable(retryAfter: 90)) }
    }
    func testOutageCanRecoverWithMatchedFallback() async throws {
        let result = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
            primary: { _, _ in throw LyricsLookupError.serviceUnavailable(retryAfter: 90) },
            fallback: { _, _ in .matched(try LRCParser.parse("[00:01.00]Synthetic")) })
        XCTAssertEqual(result.source, "AMLL 社区歌词")
    }
    func testIdentityFailureAndCancellationDoNotBroadenLookup() async throws {
        for failure in [LyricsLookupError.identityMismatch, .cancelled, .busy, .deferred(retryAfter: 0.3)] {
            do {
                _ = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
                    primary: { _, _ in throw failure },
                    fallback: { _, _ in XCTFail("Unsafe fallback"); return .noMatch })
                XCTFail("Expected terminal failure")
            } catch { XCTAssertEqual(error as? LyricsLookupError, failure) }
        }
    }
    func testFallbackOutageStateIsHonest() async throws {
        do {
            _ = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
                primary: { _, _ in .noMatch },
                fallback: { _, _ in throw LyricsLookupError.serviceUnavailable(retryAfter: 60) })
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(LyricsLookupState.failure(error as! LyricsLookupError), .serviceUnavailable)
        }
    }

    private func fullPrimaryPage() throws -> Data {
        try JSONSerialization.data(withJSONObject: (1...LRCLIBLookup.maximumSearchResults).map {
            record(["id": $0, "duration": 180])
        })
    }

    func testTruncatedPrimarySearchCanUseConsentedStrictFallback() async throws {
        let clock = LyricsAvailabilityClock()
        let primaryTransport = LyricsAvailabilityTransport(replies: [
            (404, Data()), (200, try fullPrimaryPage())])
        let fallbackTransport = LyricsAvailabilityTransport(replies: [
            (200, try JSONSerialization.data(withJSONObject: [record()]))])
        let primary = LyricsLookupClient(transport: primaryTransport,
            monotonicNow: { clock.now() }, wait: { clock.advance($0) })
        let fallback = AMLLLyricsClient(transport: fallbackTransport, now: { clock.now() })
        do {
            let result = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
                primary: { try await primary.lookup(track: $0, consent: $1) },
                fallback: { try await fallback.lookup(track: $0, consent: $1) })
            guard case .matched = result.result else { return XCTFail("Expected strict fallback lyrics") }
            XCTAssertEqual(result.source, "AMLL 社区歌词")
        } catch { XCTFail("A valid full search page must permit consented fallback: \(error)") }
        let primaryPaths = await primaryTransport.paths
        let fallbackPaths = await fallbackTransport.paths
        XCTAssertEqual(primaryPaths, ["/api/get", "/api/search"])
        XCTAssertEqual(fallbackPaths, ["/v1/lrclib/search"])
    }

    func testTruncatedPrimaryWithoutFallbackConsentDoesNotDelayAnotherTrack() async throws {
        let clock = LyricsAvailabilityClock()
        let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
        let transport = LyricsAvailabilityTransport(replies: [
            (404, Data()), (200, try fullPrimaryPage()),
            (200, try JSONSerialization.data(withJSONObject: record(["trackName": another.title, "duration": 180])))])
        let primary = LyricsLookupClient(transport: transport,
            monotonicNow: { clock.now() }, wait: { clock.advance($0) })
        var controllerNotBefore: TimeInterval = 0
        do {
            _ = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: false,
                primary: { try await primary.lookup(track: $0, consent: $1) },
                fallback: { _, _ in XCTFail("No AMLL consent"); return .noMatch })
            XCTFail("A full page cannot establish uniqueness")
        } catch {
            let failure = try XCTUnwrap(error as? LyricsLookupError)
            XCTAssertEqual(failure, .searchResultsTruncated)
            XCTAssertEqual(LyricsLookupState.failure(failure), .searchResultsTruncated)
            XCTAssertNil(LyricsRetryPolicy.nextAttemptAt(after: failure, completedAttempts: 1, now: clock.now()))
            let cooldown = LyricsRetryPolicy.cooldownUntil(after: failure, completedAttempts: 1, now: clock.now())
            XCTAssertNil(cooldown, "Search coverage must not impose a provider outage cooldown")
            controllerNotBefore = cooldown ?? 0
        }
        // Retain ordinary request spacing, then use the same client and the
        // controller's actual cooldown policy for the next song.
        clock.advance(1)
        guard clock.now() >= controllerNotBefore else { return XCTFail("Previous search coverage blocked another track") }
        guard case .matched = try await primary.lookup(track: another, consent: true) else {
            return XCTFail("Another track should remain eligible after ordinary request spacing")
        }
        let paths = await transport.paths
        XCTAssertEqual(paths, ["/api/get", "/api/search", "/api/get"])
    }

    func testTruncatedPrimaryStatusSurvivesFallbackMissOrUnavailable() async throws {
        for fallbackBody in [try JSONSerialization.data(withJSONObject: []),
                             try JSONSerialization.data(withJSONObject: [record(["trackName": "Different recording"])]),
                             try JSONSerialization.data(withJSONObject: [record(["plainLyrics": "", "syncedLyrics": ""])])] {
            let clock = LyricsAvailabilityClock()
            let primaryTransport = LyricsAvailabilityTransport(replies: [(404, Data()), (200, try fullPrimaryPage())])
            let fallbackTransport = LyricsAvailabilityTransport(replies: [(200, fallbackBody)])
            let primary = LyricsLookupClient(transport: primaryTransport,
                monotonicNow: { clock.now() }, wait: { clock.advance($0) })
            let fallback = AMLLLyricsClient(transport: fallbackTransport, now: { clock.now() })
            do {
                _ = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
                    primary: { try await primary.lookup(track: $0, consent: $1) },
                    fallback: { try await fallback.lookup(track: $0, consent: $1) })
                XCTFail("A fallback miss cannot turn incomplete primary coverage into no-match")
            } catch {
                let failure = try XCTUnwrap(error as? LyricsLookupError)
                XCTAssertEqual(failure, .searchResultsTruncated)
                XCTAssertEqual(LyricsLookupState.failure(failure), .searchResultsTruncated)
                XCTAssertNil(LyricsRetryPolicy.cooldownUntil(after: failure, completedAttempts: 1, now: clock.now()))
            }
            let fallbackPaths = await fallbackTransport.paths
            XCTAssertEqual(fallbackPaths, ["/v1/lrclib/search"])
        }
    }

    func testMalformedPrimarySearchStillCannotEnterFallback() async throws {
        var malformed = Array(repeating: record(["duration": 180]), count: LRCLIBLookup.maximumSearchResults)
        malformed[malformed.count - 1]["duration"] = "invalid"
        for payload in [Data("[".utf8), try JSONSerialization.data(withJSONObject: malformed)] {
            let clock = LyricsAvailabilityClock()
            let transport = LyricsAvailabilityTransport(replies: [(404, Data()), (200, payload)])
            let primary = LyricsLookupClient(transport: transport,
                monotonicNow: { clock.now() }, wait: { clock.advance($0) })
            do {
                _ = try await DualLyricsLookup.lookup(track: track(), lrclibConsent: true, amllConsent: true,
                    primary: { try await primary.lookup(track: $0, consent: $1) },
                    fallback: { _, _ in XCTFail("Malformed responses remain terminal"); return .noMatch })
                XCTFail("Expected unchanged malformed-response rejection")
            } catch { XCTAssertEqual(error as? LyricsLookupError, .invalidResponse) }
        }
    }

    func testAMLLLocalSpacingOnlyDefersTheNextTrackBriefly() async throws {
        let clock = LyricsAvailabilityClock()
        let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
        let transport = LyricsAvailabilityTransport(replies: [
            (200, try JSONSerialization.data(withJSONObject: [record()])),
            (200, try JSONSerialization.data(withJSONObject: [record(["trackName": another.title])]))])
        let client = AMLLLyricsClient(transport: transport, now: { clock.now() })
        _ = try await client.lookup(track: track(), consent: true)
        do { _ = try await client.lookup(track: another, consent: true); XCTFail("Ordinary spacing still applies") }
        catch {
            let failure = try XCTUnwrap(error as? LyricsLookupError)
            guard case .deferred(let delay) = failure else { return XCTFail("Expected local AMLL spacing") }
            XCTAssertEqual(delay, LRCLIBLookup.minimumRequestGap, accuracy: 0.000_001)
            XCTAssertNil(LyricsRetryPolicy.cooldownUntil(after: failure, completedAttempts: 1, now: clock.now()))
            XCTAssertEqual(try XCTUnwrap(LyricsRetryPolicy.nextAttemptAt(after: failure, completedAttempts: 0, now: clock.now())),
                           clock.now() + LRCLIBLookup.minimumRequestGap, accuracy: 0.000_001)
        }
        clock.advance(1)
        guard case .matched = try await client.lookup(track: another, consent: true) else {
            return XCTFail("Local spacing must not impose an outage cooldown")
        }
        let paths = await transport.paths
        XCTAssertEqual(paths, ["/v1/lrclib/search", "/v1/lrclib/search"])
    }

    private func dual(_ track: LyricsLookupTrack, primary: LyricsLookupClient,
                      fallback: AMLLLyricsClient) async throws -> SourcedLyricsResult {
        try await DualLyricsLookup.lookup(track: track, lrclibConsent: true, amllConsent: true,
            primary: { try await primary.lookup(track: $0, consent: $1) },
            fallback: { try await fallback.lookup(track: $0, consent: $1) })
    }

    func testFallbackOutageDoesNotBlockHealthyPrimaryForAnotherTrack() async throws {
        let clock = LyricsAvailabilityClock()
        let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
        let primaryTransport = LyricsAvailabilityTransport(replies: [
            (404, Data()), (200, Data("[]".utf8)),
            (200, try JSONSerialization.data(withJSONObject: record(["trackName": another.title, "duration": 180])))])
        let fallbackTransport = LyricsAvailabilityTransport(replies: [(503, Data())], retryAfter: "90")
        let primary = LyricsLookupClient(transport: primaryTransport,
            monotonicNow: { clock.now() }, wait: { clock.advance($0) })
        let fallback = AMLLLyricsClient(transport: fallbackTransport, now: { clock.now() })
        do { _ = try await dual(track(), primary: primary, fallback: fallback); XCTFail("Expected fallback outage") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .serviceUnavailable(retryAfter: 90)) }
        clock.advance(1)
        let result = try await dual(another, primary: primary, fallback: fallback)
        guard case .matched = result.result else { return XCTFail("Healthy primary should serve another track") }
        XCTAssertEqual(result.source, "LRCLIB 社区歌词")
        let primaryPaths = await primaryTransport.paths, fallbackPaths = await fallbackTransport.paths
        XCTAssertEqual(primaryPaths, ["/api/get", "/api/search", "/api/get"])
        XCTAssertEqual(fallbackPaths, ["/v1/lrclib/search"])
    }

    func testPrimaryOutageDoesNotBlockHealthyFallbackForAnotherTrack() async throws {
        let clock = LyricsAvailabilityClock()
        let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
        let primaryTransport = LyricsAvailabilityTransport(replies: [(503, Data())], retryAfter: "90")
        let fallbackTransport = LyricsAvailabilityTransport(replies: [
            (200, Data("[]".utf8)), (200, try JSONSerialization.data(withJSONObject: [record(["trackName": another.title])]))])
        let primary = LyricsLookupClient(transport: primaryTransport,
            monotonicNow: { clock.now() }, wait: { clock.advance($0) })
        let fallback = AMLLLyricsClient(transport: fallbackTransport, now: { clock.now() })
        do { _ = try await dual(track(), primary: primary, fallback: fallback); XCTFail("Expected primary outage") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .serviceUnavailable(retryAfter: 90)) }
        clock.advance(1)
        let result = try await dual(another, primary: primary, fallback: fallback)
        guard case .matched = result.result else { return XCTFail("Healthy fallback should serve another track") }
        XCTAssertEqual(result.source, "AMLL 社区歌词")
        let primaryPaths = await primaryTransport.paths, fallbackPaths = await fallbackTransport.paths
        XCTAssertEqual(primaryPaths, ["/api/get"])
        XCTAssertEqual(fallbackPaths, ["/v1/lrclib/search", "/v1/lrclib/search"])
    }

    func testBothProvidersKeepIndependentServerCooldownsAcrossTracks() async throws {
        let clock = LyricsAvailabilityClock()
        let primaryTransport = LyricsAvailabilityTransport(replies: [
            (503, Data()), (404, Data()), (200, Data("[]".utf8)),
            (404, Data()), (200, Data("[]".utf8))], retryAfter: "90")
        let fallbackTransport = LyricsAvailabilityTransport(replies: [
            (429, Data()), (200, try JSONSerialization.data(withJSONObject: [record()]))], retryAfter: "120")
        let primary = LyricsLookupClient(transport: primaryTransport,
            monotonicNow: { clock.now() }, wait: { clock.advance($0) })
        let fallback = AMLLLyricsClient(transport: fallbackTransport, now: { clock.now() })
        do { _ = try await dual(track(), primary: primary, fallback: fallback); XCTFail("Expected both sources unavailable") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 120)) }
        clock.advance(10)
        let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
        do { _ = try await dual(another, primary: primary, fallback: fallback); XCTFail("Neither server deadline has expired") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 110)) }
        let blockedPrimary = await primaryTransport.paths, blockedFallback = await fallbackTransport.paths
        XCTAssertEqual(blockedPrimary.count, 1)
        XCTAssertEqual(blockedFallback.count, 1)

        clock.advance(80)
        do { _ = try await dual(another, primary: primary, fallback: fallback); XCTFail("Only primary cooldown has expired") }
        catch {
            guard case .rateLimited(let remaining) = error as? LyricsLookupError else { return XCTFail("Expected fallback cooldown") }
            XCTAssertEqual(remaining, 29.7, accuracy: 0.000_001)
        }
        let readyPrimary = await primaryTransport.paths, stillBlockedFallback = await fallbackTransport.paths
        XCTAssertEqual(readyPrimary, ["/api/get", "/api/get", "/api/search"])
        XCTAssertEqual(stillBlockedFallback.count, 1)
        clock.advance(31)
        let result = try await dual(track(), primary: primary, fallback: fallback)
        guard case .matched = result.result else { return XCTFail("Both cooldowns have expired independently") }
        XCTAssertEqual(result.source, "AMLL 社区歌词")
        let finalPrimary = await primaryTransport.paths, finalFallback = await fallbackTransport.paths
        XCTAssertEqual(finalPrimary.count, 5)
        XCTAssertEqual(finalFallback.count, 2)
    }

    func testProviderServerCooldownFloorSurvivesTrackChanges() async throws {
        for isPrimary in [true, false] {
            for status in [429, 503] {
                for retryAfter in ["0", "1"] {
                    let clock = LyricsAvailabilityClock()
                    let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
                    let payload = try JSONSerialization.data(withJSONObject: isPrimary
                        ? record(["trackName": another.title, "duration": 180]) as Any
                        : [record(["trackName": another.title])] as Any)
                    let transport = LyricsAvailabilityTransport(replies: [(status, Data()), (200, payload)], retryAfter: retryAfter)
                    let primary = LyricsLookupClient(transport: transport,
                        monotonicNow: { clock.now() }, wait: { clock.advance($0) })
                    let fallback = AMLLLyricsClient(transport: transport, now: { clock.now() })
                    let lookup: DualLyricsLookup.Lookup = { track, consent in
                        if isPrimary { return try await primary.lookup(track: track, consent: consent) }
                        return try await fallback.lookup(track: track, consent: consent)
                    }
                    do { _ = try await lookup(track(), true); XCTFail("Expected real server response") }
                    catch { XCTAssertNotNil(error as? LyricsLookupError) }
                    clock.advance(1)
                    do { _ = try await lookup(another, true); XCTFail("Track changes must retain the thirty-second server floor") }
                    catch { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 29)) }
                    let blockedPaths = await transport.paths
                    XCTAssertEqual(blockedPaths.count, 1)
                    clock.advance(30)
                    guard case .matched = try await lookup(another, true) else { return XCTFail("Server cooldown should expire") }
                    let finalPaths = await transport.paths
                    XCTAssertEqual(finalPaths.count, 2)
                }
            }
        }
    }

    func testCancelledLateServerCooldownIsRetainedOnlyFromTheRequestedSource() async throws {
        for isPrimary in [true, false] {
            for trustedURL in [true, false] {
                for status in [429, 503] {
                    let clock = LyricsAvailabilityClock()
                    let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
                    let payload = try JSONSerialization.data(withJSONObject: isPrimary
                        ? record(["trackName": another.title, "duration": 180]) as Any
                        : [record(["trackName": another.title])] as Any)
                    let transport = DeferredCooldownTransport(status: status, trustedURL: trustedURL, successBody: payload)
                    let primary = LyricsLookupClient(transport: transport,
                        monotonicNow: { clock.now() }, wait: { clock.advance($0) })
                    let fallback = AMLLLyricsClient(transport: transport, now: { clock.now() })
                    let lookup: DualLyricsLookup.Lookup = { track, consent in
                        if isPrimary { return try await primary.lookup(track: track, consent: consent) }
                        return try await fallback.lookup(track: track, consent: consent)
                    }
                    let fixture = try track()
                    let retired = Task { try await lookup(fixture, true) }
                    try await transport.waitForFirstRequest()
                    retired.cancel()
                    await transport.releaseFirst()
                    do { _ = try await retired.value; XCTFail("Cancelled results must remain retired") }
                    catch { XCTAssertEqual(error as? LyricsLookupError, .cancelled) }
                    clock.advance(1)
                    do {
                        let result = try await lookup(another, true)
                        if trustedURL { XCTFail("A known late server cooldown must survive cancellation") }
                        else if case .matched = result { } else { XCTFail("Wrong-source cooldown must not block the provider") }
                    } catch {
                        if trustedURL { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 89)) }
                        else { XCTFail("Wrong-source response supplied a cooldown: \(error)") }
                    }
                    let count = await transport.count
                    XCTAssertEqual(count, trustedURL ? 1 : 2)
                }
            }
        }
    }
}

private final class LyricsAvailabilityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

private actor LyricsAvailabilityTransport: LyricsLookupTransport {
    let replies: [(Int, Data)]
    let retryAfter: String?
    private(set) var paths: [String] = []
    init(replies: [(Int, Data)], retryAfter: String? = nil) {
        self.replies = replies; self.retryAfter = retryAfter
    }
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        let index = paths.count
        paths.append(request.url.path)
        guard replies.indices.contains(index) else { throw LyricsLookupError.invalidResponse }
        return LyricsLookupResponse(url: request.url, statusCode: replies[index].0,
                                    retryAfter: retryAfter, body: replies[index].1)
    }
}

private actor DeferredCooldownTransport: LyricsLookupTransport {
    let status: Int
    let trustedURL: Bool
    let successBody: Data
    private var held: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    private enum FixtureFailure: Error { case timeout }
    init(status: Int, trustedURL: Bool, successBody: Data) {
        self.status = status; self.trustedURL = trustedURL; self.successBody = successBody
    }
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        count += 1
        if count == 1 {
            await withCheckedContinuation { held = $0 }
            let responseURL = trustedURL ? request.url : URL(string: "https://wrong-source.invalid/api/get")!
            return LyricsLookupResponse(url: responseURL, statusCode: status, retryAfter: "90", body: Data())
        }
        return LyricsLookupResponse(url: request.url, statusCode: 200, body: successBody)
    }
    func waitForFirstRequest() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while held == nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureFailure.timeout }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func releaseFirst() {
        let continuation = held; held = nil
        continuation?.resume()
    }
}

private actor AMLLFixtureTransport: LyricsLookupTransport {
    private(set) var count = 0
    let status: Int
    let cancelOnFetch: Bool
    init(status: Int = 200, cancelOnFetch: Bool = false) { self.status = status; self.cancelOnFetch = cancelOnFetch }
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        count += 1
        if cancelOnFetch { withUnsafeCurrentTask { $0?.cancel() } }
        return LyricsLookupResponse(url: request.url, statusCode: status, retryAfter: "90", body: Data("[]".utf8))
    }
}

extension AMLLLyricsLookupTests {
    func testClientRevokedConsentMakesNoRequest() async throws {
        let transport = AMLLFixtureTransport()
        let client = AMLLLyricsClient(transport: transport)
        do { _ = try await client.lookup(track: track(), consent: false); XCTFail("Consent required") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .consentRequired) }
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }
    func testClientServerCooldownPersistsAcrossTracksFor429And503() async throws {
        for status in [429, 503] {
            let clock = LyricsAvailabilityClock()
            let transport = AMLLFixtureTransport(status: status)
            let client = AMLLLyricsClient(transport: transport, now: { clock.now() })
            do { _ = try await client.lookup(track: track(), consent: true); XCTFail("Expected server cooldown") }
            catch {
                let expected: LyricsLookupError = status == 429 ? .rateLimited(retryAfter: 90) : .serviceUnavailable(retryAfter: 90)
                XCTAssertEqual(error as? LyricsLookupError, expected)
            }
            clock.advance(10)
            let another = try LyricsLookupTrack(title: "Another Comet", artist: "Glass Orchard", album: "Orbit", duration: 180)
            do { _ = try await client.lookup(track: another, consent: true); XCTFail("Expected retained server cooldown") }
            catch { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 80)) }
            let count = await transport.count
            XCTAssertEqual(count, 1)
        }
    }
    func testClientRejectsLateResponseAfterCancellation() async throws {
        let transport = AMLLFixtureTransport(cancelOnFetch: true)
        let client = AMLLLyricsClient(transport: transport)
        let fixture = try track()
        let work = Task { try await client.lookup(track: fixture, consent: true) }
        do { _ = try await work.value; XCTFail("Cancelled result must be retired") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .cancelled) }
    }
}
