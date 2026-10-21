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
        for failure in [LyricsLookupError.identityMismatch, .cancelled] {
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
    func testClientCooldownPreventsRepeated503Requests() async throws {
        let transport = AMLLFixtureTransport(status: 503)
        let client = AMLLLyricsClient(transport: transport, now: { 100 })
        do { _ = try await client.lookup(track: track(), consent: true); XCTFail("Expected 503") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .serviceUnavailable(retryAfter: 90)) }
        do { _ = try await client.lookup(track: track(), consent: true); XCTFail("Expected cooldown") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 90)) }
        let count = await transport.count
        XCTAssertEqual(count, 1)
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
