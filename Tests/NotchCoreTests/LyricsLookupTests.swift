import XCTest
@testable import NotchCore

/// Original synthetic fixtures only. No URLSession, Music.app, account, file
/// selection, filesystem scan or real lyric request is used by these tests.
final class LyricsLookupTests: XCTestCase {
    private func track(title: String = "Paper + Comet", artist: String = "Glass Orchard",
                       album: String = "Amber Orbit", duration: TimeInterval = 180) throws -> LyricsLookupTrack {
        try LyricsLookupTrack(title: title, artist: artist, album: album, duration: duration)
    }

    private func body(_ changes: [String: Any] = [:]) throws -> Data {
        var record: [String: Any] = [
            "id": 42, "trackName": "Paper + Comet", "artistName": "Glass Orchard",
            "albumName": "Amber Orbit", "duration": 180, "instrumental": false,
            "plainLyrics": "Paper comet wakes\n小小星舟 🌱",
            "syncedLyrics": "[00:01.20]Paper comet wakes\n[00:03.45]小小星舟 🌱"
        ]
        for (key, value) in changes { record[key] = value }
        return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    private func decode(_ changes: [String: Any] = [:], status: Int = 200,
                        mime: String? = "application/json") throws -> LyricsLookupResult {
        let track = try track()
        let request = try LRCLIBLookup.request(track: track, consent: true)
        return try LRCLIBLookup.decode(LyricsLookupResponse(url: request.url, statusCode: status,
                                                           contentType: mime, body: body(changes)),
                                       for: track, request: request)
    }

    private func assertError(_ expected: LyricsLookupError, _ work: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) {
            XCTAssertEqual($0 as? LyricsLookupError, expected, file: file, line: line)
        }
    }

    func testConsentIsRequiredForRequestConstruction() throws {
        let fixture = try track()
        assertError(.consentRequired) { _ = try LRCLIBLookup.request(track: fixture, consent: false) }
    }

    func testExactReadOnlyEndpointAndOnlyDisclosedFields() throws {
        let fixture = try track(title: "紙 + & #? 🌱", artist: "Café", album: "Amber=Orbit")
        let request = try LRCLIBLookup.request(track: fixture, consent: true)
        let url = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "lrclib.net")
        XCTAssertEqual(url.path, "/api/get")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.fragment)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.timeout, 10)
        XCTAssertEqual(request.maximumResponseBytes, 1_048_576)
        XCTAssertTrue(request.userAgent.contains("CodexNotchMeter/1.0.0"))
        let fields = Dictionary(uniqueKeysWithValues: try XCTUnwrap(url.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(fields.keys), Set(["track_name", "artist_name", "album_name", "duration"]))
        XCTAssertEqual(fields["track_name"], fixture.title)
        XCTAssertEqual(fields["artist_name"], fixture.artist)
        XCTAssertEqual(fields["album_name"], fixture.album)
        XCTAssertFalse(try XCTUnwrap(url.percentEncodedQuery).contains("+"))
        XCTAssertTrue(LRCLIBLookup.isAllowed(url: request.url))
    }

    func testIncompleteOversizeControlAndUnsupportedDurationAreRejected() {
        for value in ["", " \n", "Paper\nComet", "Paper\u{0000}Comet", String(repeating: "a", count: 1_025)] {
            assertError(.invalidTrack) { _ = try track(title: value) }
            assertError(.invalidTrack) { _ = try track(artist: value) }
            assertError(.invalidTrack) { _ = try track(album: value) }
        }
        for duration in [0.0, -1, 0.99, 3_600.01, .infinity, -.infinity, .nan] {
            assertError(.invalidTrack) { _ = try track(duration: duration) }
        }
        XCTAssertNoThrow(try track(duration: 1))
        XCTAssertNoThrow(try track(duration: 3_600))
        XCTAssertNoThrow(try track(title: String(repeating: "a", count: 1_024)))
    }

    func testFixedHostRejectsRedirectDestinationsAlternateEndpointsAndExtraFields() throws {
        let request = try LRCLIBLookup.request(track: track(), consent: true)
        let valid = request.url.absoluteString
        let urls = [valid.replacingOccurrences(of: "https:", with: "http:"),
                    valid.replacingOccurrences(of: "lrclib.net", with: "elsewhere.invalid"),
                    valid.replacingOccurrences(of: "lrclib.net", with: "lrclib.net.elsewhere.invalid"),
                    valid.replacingOccurrences(of: "lrclib.net", with: "lrclib.net:443"),
                    valid.replacingOccurrences(of: "lrclib.net", with: "name@lrclib.net"),
                    valid.replacingOccurrences(of: "/api/get", with: "/api/search"),
                    valid.replacingOccurrences(of: "/api/get", with: "/api/get/42"),
                    valid + "#fragment", valid + "&token=fixture", valid + "&duration=180"]
        for string in urls {
            XCTAssertFalse(LRCLIBLookup.isAllowed(url: try XCTUnwrap(URL(string: string))))
        }
    }

    func testResponseMustHaveExactOriginalURLNotMerelySameHost() throws {
        let fixture = try track()
        let request = try LRCLIBLookup.request(track: fixture, consent: true)
        let otherRequest = try LRCLIBLookup.request(track: track(title: "Other Comet"), consent: true)
        let response = LyricsLookupResponse(url: otherRequest.url, statusCode: 200, body: try body())
        assertError(.requestNotAllowed) { _ = try LRCLIBLookup.decode(response, for: fixture, request: request) }
    }

    func testSynchronizedUnicodeLinesRetainOnlyProvidedTiming() throws {
        guard case .matched(let document) = try decode(),
              case .synchronized(let cues) = document.content else { return XCTFail("Expected timed fixture") }
        XCTAssertEqual(cues.map(\.startTime), [1.2, 3.45])
        XCTAssertEqual(cues.map(\.text), ["Paper comet wakes", "小小星舟 🌱"])
    }

    func testPlainInstrumentalUnavailableAndNoMatchRemainDistinct() throws {
        guard case .matched(let plain) = try decode(["syncedLyrics": NSNull()]) else {
            return XCTFail("Expected plain fixture")
        }
        XCTAssertEqual(plain.content, .plain(["Paper comet wakes", "小小星舟 🌱"]))
        XCTAssertEqual(try decode(["instrumental": true, "syncedLyrics": NSNull(), "plainLyrics": NSNull()]),
                       .matched(.instrumental))
        XCTAssertEqual(try decode(["syncedLyrics": NSNull(), "plainLyrics": NSNull()]), .unavailable)
        XCTAssertEqual(try decode(status: 404, mime: "text/html"), .noMatch)
    }

    func testConflictingInstrumentalRecordIsNotAccepted() {
        assertError(.invalidResponse) { _ = try decode(["instrumental": true]) }
    }

    func testNoFuzzyFirstResultOrEditionMatching() {
        for changes in [["trackName": "Paper Comet"], ["trackName": "Paper + Comet (Live)"],
                        ["artistName": "Glass Orchard & Guest"], ["albumName": "Amber Orbit Deluxe"]] {
            assertError(.identityMismatch) { _ = try decode(changes) }
        }
        assertError(.identityMismatch) { _ = try decode(["duration": 182.001]) }
        assertError(.identityMismatch) { _ = try decode(["duration": 177.999]) }
        XCTAssertNoThrow(try decode(["duration": 182]))
        XCTAssertNoThrow(try decode(["duration": 178]))
        XCTAssertNoThrow(try decode(["trackName": "  PAPER + COMET  "]))
    }

    func testUnicodeCanonicalEquivalenceButNoDiacriticFolding() throws {
        let fixture = try track(title: "Café")
        let request = try LRCLIBLookup.request(track: fixture, consent: true)
        let response = LyricsLookupResponse(url: request.url, statusCode: 200,
                                            body: try body(["trackName": "Cafe\u{301}"]))
        XCTAssertNoThrow(try LRCLIBLookup.decode(response, for: fixture, request: request))
        let wrong = LyricsLookupResponse(url: request.url, statusCode: 200,
                                         body: try body(["trackName": "Cafe"]))
        assertError(.identityMismatch) { _ = try LRCLIBLookup.decode(wrong, for: fixture, request: request) }
    }

    func testMissingInvalidAndUnboundedResponseMetadataFailsClosed() throws {
        let invalid: [[String: Any]] = [["id": 0], ["id": -1], ["id": "42"], ["instrumental": "false"],
                                       ["albumName": NSNull()], ["artistName": ""], ["duration": "180"],
                                       ["duration": 3_601], ["trackName": String(repeating: "a", count: 1_025)]]
        for changes in invalid {
            assertError(.invalidResponse) { _ = try decode(changes) }
        }
    }

    func testMalformedJSONAndSearchArraysAreNeverAutoSelected() throws {
        let fixture = try track()
        let request = try LRCLIBLookup.request(track: fixture, consent: true)
        for payload in [Data("{".utf8), Data("[]".utf8), Data("null".utf8),
                        Data("[".utf8) + (try body()) + Data("]".utf8)] {
            assertError(.invalidResponse) {
                _ = try LRCLIBLookup.decode(LyricsLookupResponse(url: request.url, statusCode: 200, body: payload),
                                            for: fixture, request: request)
            }
        }
    }

    func testHTTPStatusAndContentTypeAreCheckedBeforeBody() {
        for status in [201, 301, 302, 307, 308, 401, 403, 500] {
            assertError(.invalidResponse) { _ = try decode(status: status) }
        }
        for mime in [nil, "text/html", "text/plain"] {
            assertError(.invalidResponse) { _ = try decode(mime: mime) }
        }
        XCTAssertNoThrow(try decode(mime: "application/json; charset=utf-8"))
    }

    func testRawAndDecodedLyricByteLimits() throws {
        let fixture = try track()
        let request = try LRCLIBLookup.request(track: fixture, consent: true)
        let response = LyricsLookupResponse(url: request.url, statusCode: 200,
                                            body: Data(repeating: 32, count: LRCLIBLookup.maximumResponseBytes + 1))
        assertError(.tooLarge) { _ = try LRCLIBLookup.decode(response, for: fixture, request: request) }
        assertError(.tooLarge) {
            _ = try decode(["plainLyrics": String(repeating: "a", count: LRCParser.maximumInputBytes + 1)])
        }
    }

    func testStreamedPayloadIsBoundedWithoutContentLength() throws {
        var buffer = LyricsResponseBuffer()
        let half = Data(repeating: 32, count: LRCLIBLookup.maximumResponseBytes / 2)
        try buffer.append(half)
        try buffer.append(half)
        XCTAssertEqual(buffer.data.count, LRCLIBLookup.maximumResponseBytes)
        assertError(.tooLarge) { try buffer.append(Data([32])) }
        XCTAssertEqual(buffer.data.count, LRCLIBLookup.maximumResponseBytes)
        var empty = LyricsResponseBuffer()
        assertError(.tooLarge) {
            try empty.append(Data(repeating: 32, count: LRCLIBLookup.maximumResponseBytes + 1))
        }
        XCTAssertTrue(empty.data.isEmpty)
    }

    func testMalformedSyncedFieldOnlyFallsBackToExplicitPlainText() throws {
        guard case .matched(let document) = try decode(["syncedLyrics": "[00:99]Broken fixture"]) else {
            return XCTFail("Expected plain fallback")
        }
        XCTAssertEqual(document.content, .plain(["Paper comet wakes", "小小星舟 🌱"]))
        assertError(.invalidLyrics) { _ = try decode(["syncedLyrics": "Untimed", "plainLyrics": NSNull()]) }
        assertError(.invalidLyrics) { _ = try decode(["syncedLyrics": NSNull(), "plainLyrics": "[00:01]Timed"]) }
        assertError(.invalidLyrics) { _ = try decode(["syncedLyrics": "[03:03]Beyond duration"]) }
        assertError(.invalidLyrics) { _ = try decode(["syncedLyrics": "[00:01]\n[00:02]"]) }
    }

    func testConflictingEmbeddedLRCIdentityIsRejected() {
        assertError(.identityMismatch) { _ = try decode(["syncedLyrics": "[ti:Another Comet]\n[00:01]Paper"]) }
        assertError(.identityMismatch) { _ = try decode(["syncedLyrics": "[ar:Other Artist]\n[00:01]Paper"]) }
        assertError(.identityMismatch) { _ = try decode(["syncedLyrics": "[al:Another Album]\n[00:01]Paper"]) }
    }

    func testRetryAfterParsingHonorsLongValuesAndHTTPDate() throws {
        XCTAssertEqual(LRCLIBLookup.retryDelay("90"), 90)
        XCTAssertEqual(LRCLIBLookup.retryDelay("999999"), 999_999)
        XCTAssertEqual(LRCLIBLookup.retryDelay("0"), LRCLIBLookup.minimumRequestGap)
        for value in [nil, "-1", "NaN", "1.5", "untrusted body", String(repeating: "9", count: 129)] {
            XCTAssertEqual(LRCLIBLookup.retryDelay(value), 60)
        }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-16T07:00:00Z"))
        XCTAssertEqual(LRCLIBLookup.retryDelay("Fri, 16 Oct 2026 07:02:00 GMT", now: now), 120)
    }

    func testRateLimitStatusDoesNotRequireJSONErrorBody() throws {
        let fixture = try track()
        let request = try LRCLIBLookup.request(track: fixture, consent: true)
        for status in [429, 503] {
            let response = LyricsLookupResponse(url: request.url, statusCode: status,
                                                contentType: "text/html", retryAfter: "90", body: Data())
            let expected: LyricsLookupError = status == 429 ? .rateLimited(retryAfter: 90) : .serviceUnavailable(retryAfter: 90)
            assertError(expected) { _ = try LRCLIBLookup.decode(response, for: fixture, request: request) }
        }
    }

    func testLocalUTF8InputAndByteBounds() throws {
        let local = try LyricsLocalImport.parse(data: Data("[00:01]紙の彗星 🌱".utf8))
        guard case .synchronized(let cues) = local.content else { return XCTFail("Expected local fixture") }
        XCTAssertEqual(cues.first?.text, "紙の彗星 🌱")
        XCTAssertEqual(try LyricsLocalImport.parse(data: Data()).content, .unavailable)
        assertError(.invalidUTF8) { _ = try LyricsLocalImport.parse(data: Data([0xFF, 0xFE, 0x00])) }
        assertError(.tooLarge) {
            _ = try LyricsLocalImport.parse(data: Data(repeating: 32, count: LRCParser.maximumInputBytes + 1))
        }
        assertError(.invalidLyrics) {
            _ = try LyricsLocalImport.parse(data: Data(String(repeating: "a", count: LRCParser.maximumLineBytes + 1).utf8))
        }
    }

    func testNoTransportCallWithoutConsentOrWhenAlreadyCancelled() async throws {
        let mock = ControlledTransport()
        let client = LyricsLookupClient(transport: mock)
        let fixture = try track()
        do { _ = try await client.lookup(track: fixture, consent: false); XCTFail("Expected consent gate") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .consentRequired) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.lookup(track: fixture, consent: true)
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .cancelled) }
        let count = await mock.callCount
        XCTAssertEqual(count, 0)
    }

    func testSingleFlightAndLateCancelledResultCannotEscape() async throws {
        let mock = ControlledTransport()
        let client = LyricsLookupClient(transport: mock)
        let fixture = try track()
        let pending = Task { try await client.lookup(track: fixture, consent: true) }
        try await mock.waitForRequest()
        do { _ = try await client.lookup(track: fixture, consent: true); XCTFail("Expected single flight") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .busy) }
        pending.cancel()
        // This intentionally noncooperative mock returns success AFTER cancel.
        await mock.complete(body: try body())
        do { _ = try await pending.value; XCTFail("A late result must not be accepted") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .cancelled) }
        let count = await mock.callCount
        XCTAssertEqual(count, 1)
    }

    func testMinimumGapAndRetryAfterPersistAcrossTracksWithoutRetry() async throws {
        let clock = FixtureClock()
        let mock = ControlledTransport()
        let client = LyricsLookupClient(transport: mock, monotonicNow: { clock.now() })
        let fixture = try track()
        let first = Task { try await client.lookup(track: fixture, consent: true) }
        try await mock.waitForRequest()
        await mock.complete(body: Data(), statusCode: 429, retryAfter: "90")
        do { _ = try await first.value; XCTFail("Expected server cooldown") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 90)) }
        clock.advance(10)
        do { _ = try await client.lookup(track: track(title: "Another Track"), consent: true); XCTFail("Expected retained cooldown") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .rateLimited(retryAfter: 80)) }
        let count = await mock.callCount
        XCTAssertEqual(count, 1)
    }

    func testSuccessfulFetchAlsoEnforcesMinimumGap() async throws {
        let clock = FixtureClock()
        let mock = ControlledTransport()
        let client = LyricsLookupClient(transport: mock, monotonicNow: { clock.now() })
        let fixture = try track()
        let first = Task { try await client.lookup(track: fixture, consent: true) }
        try await mock.waitForRequest()
        await mock.complete(body: try body())
        _ = try await first.value
        do { _ = try await client.lookup(track: fixture, consent: true); XCTFail("Expected minimum gap") }
        catch {
            guard let failure = error as? LyricsLookupError, case .rateLimited(let seconds) = failure else {
                return XCTFail("Expected sanitized cooldown")
            }
            XCTAssertEqual(seconds, 0.3, accuracy: 0.000_001)
        }
        let count = await mock.callCount
        XCTAssertEqual(count, 1)
    }

    func testKnownTransportFailureStatesStayDistinctWithoutAutomaticRetry() async throws {
        let failures: [LyricsLookupError] = [.offline, .timedOut, .cancelled]
        for failure in failures {
            let mock = KnownFailureTransport(failure: failure)
            let client = LyricsLookupClient(transport: mock)
            do { _ = try await client.lookup(track: track(), consent: true); XCTFail("Expected transport state") }
            catch { XCTAssertEqual(error as? LyricsLookupError, failure) }
            let count = await mock.callCount
            XCTAssertEqual(count, 1)
        }
    }

    func testTransportErrorNeverEscapesWithRawContext() async throws {
        let client = LyricsLookupClient(transport: FailingTransport())
        do { _ = try await client.lookup(track: track(), consent: true); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .transportFailure) }
    }
}

private actor ControlledTransport: LyricsLookupTransport {
    private var pending: CheckedContinuation<LyricsLookupResponse, Error>?
    private var request: LyricsLookupRequest?
    private enum FixtureFailure: Error { case requestDeadline }
    private var aborted = false
    private(set) var callCount = 0

    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        guard !aborted else { throw FixtureFailure.requestDeadline }
        callCount += 1
        self.request = request
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func waitForRequest() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        do {
            while request == nil {
                guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else {
                    throw FixtureFailure.requestDeadline
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            aborted = true
            pending?.resume(throwing: FixtureFailure.requestDeadline)
            pending = nil
            throw error
        }
    }

    func complete(body: Data, statusCode: Int = 200, retryAfter: String? = nil) {
        guard let request, let pending else { return }
        self.pending = nil
        pending.resume(returning: LyricsLookupResponse(url: request.url, statusCode: statusCode,
                                                       retryAfter: retryAfter, body: body))
    }
}

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

private struct FailingTransport: LyricsLookupTransport {
    private struct UntrustedTransportError: Error {}
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        throw UntrustedTransportError()
    }
}

private actor KnownFailureTransport: LyricsLookupTransport {
    let failure: LyricsLookupError
    private(set) var callCount = 0
    init(failure: LyricsLookupError) { self.failure = failure }
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        callCount += 1
        throw failure
    }
}
