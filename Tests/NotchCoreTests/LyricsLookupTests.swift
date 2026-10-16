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

    private func searchBody(_ records: [[String: Any]]) throws -> Data {
        let decoded = try records.map { changes -> Any in
            try JSONSerialization.jsonObject(with: body(changes))
        }
        return try JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys])
    }

    private func searchDecode(_ records: [[String: Any]], for fixture: LyricsLookupTrack? = nil) throws -> LyricsLookupResult {
        let fixture: LyricsLookupTrack = try fixture ?? track()
        let request = try XCTUnwrap(LRCLIBLookup.requests(track: fixture, consent: true).first { $0.url.path == "/api/search" })
        return try LRCLIBLookup.decode(LyricsLookupResponse(url: request.url, statusCode: 200, body: searchBody(records)),
                                       for: fixture, request: request)
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
        XCTAssertTrue(request.userAgent.contains("CodexNotchMeter/1.0.0 "))
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
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.contains("\n") {
                assertError(.invalidTrack) { _ = try track(album: value) }
            }
        }
        let invalidDurations: [TimeInterval] = [0.0, -1, 0.99, 3_600.01, .infinity, -.infinity, .nan]
        for duration in invalidDurations {
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

    func testBoundedStructuredSearchPlanPreservesOriginalMetadata() throws {
        let fixture = try track(title: #"Paper Moon (From "Example Film")"#, duration: 200)
        let plan = try LRCLIBLookup.requests(track: fixture, consent: true)
        XCTAssertEqual(plan.count, LRCLIBLookup.maximumRequestsPerLookup)
        XCTAssertEqual(plan.map { $0.url.path }, ["/api/get", "/api/search", "/api/search"])
        let queries = try plan.map { request -> [String: String] in
            let items = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(LRCLIBLookup.isAllowed(url: request.url))
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(queries[1], ["track_name": fixture.title, "artist_name": fixture.artist])
        XCTAssertEqual(queries[2], ["track_name": "Paper Moon", "artist_name": fixture.artist])
        XCTAssertEqual(fixture.title, #"Paper Moon (From "Example Film")"#)
        XCTAssertEqual(fixture.album, "Amber Orbit")
        assertError(.consentRequired) { _ = try LRCLIBLookup.requests(track: fixture, consent: false) }
        XCTAssertEqual(try LRCLIBLookup.requests(track: track(), consent: true).count, 2)
    }

    func testAbsentAlbumSkipsExactLookupWithoutRelaxingRequiredIdentity() throws {
        for album in ["", "   "] {
            let fixture = try track(album: album)
            let plan = try LRCLIBLookup.requests(track: fixture, consent: true)
            XCTAssertEqual(plan.count, 1)
            XCTAssertEqual(plan.first?.url.path, "/api/search")
            assertError(.invalidTrack) { _ = try LRCLIBLookup.request(track: fixture, consent: true) }
            guard case .matched = try searchDecode([[:]], for: fixture) else { return XCTFail("Expected album-free match") }
        }
        assertError(.invalidTrack) { _ = try track(title: "", album: "") }
        assertError(.invalidTrack) { _ = try track(artist: "", album: "") }
        assertError(.invalidTrack) { _ = try track(album: "", duration: 0) }
        assertError(.invalidTrack) { _ = try track(album: "\u{0000}") }
    }

    func testSearchEndpointRejectsKeywordOverridesExtraFieldsAndDuplicateQueries() throws {
        let request = try XCTUnwrap(LRCLIBLookup.requests(track: track(title: "Paper + Comet"), consent: true).last)
        let valid = request.url.absoluteString
        XCTAssertFalse(valid.contains("+"))
        for bad in [valid + "&q=anything", valid + "&album_name=other", valid + "&duration=180",
                    valid + "&artist_name=Other", valid.replacingOccurrences(of: "/api/search", with: "/api/search/"),
                    valid.replacingOccurrences(of: "lrclib.net", with: "elsewhere.invalid")] {
            XCTAssertFalse(LRCLIBLookup.isAllowed(url: try XCTUnwrap(URL(string: bad))))
        }
    }

    func testNarrowEnglishAndChinesePresentationSuffixesMatchWithAlbumVariation() throws {
        let fixtures: [(String, String, String)] = [
            (#"Paper Moon (From "Example Film")"#, "Paper Moon", "Amber Orbit (Deluxe Edition)"),
            ("纸月亮（电影《示例》主题曲）", "纸月亮", "Amber Orbit 豪華版"),
            ("紙月亮 (電視劇《示例》片尾曲)", "紙月亮", "Different Collection")
        ]
        for (original, title, album) in fixtures {
            let fixture = try track(title: original, duration: 200)
            guard case .matched(let document) = try searchDecode([["trackName": title, "albumName": album,
                                                                    "duration": 201]], for: fixture) else {
                return XCTFail("Expected narrowly normalized match")
            }
            guard case .synchronized = document.content else { return XCTFail("Expected real timing") }
            XCTAssertEqual(try LRCLIBLookup.requests(track: fixture, consent: true).count, 3)
        }
    }

    func testVersionAndUnknownSuffixesAreNeverRemovedIncludingNestedFilmMarkers() throws {
        let markers = ["Live", "Remix", "Acoustic", "Cover", "Karaoke", "Instrumental", "Radio Edit",
                       "Remastered", "Demo", "Mono", "Stereo", "Original Mix", "Clean", "Explicit",
                       "Sped Up", "Slowed", "Nightcore", "English Version", "Reprise", "Part II", "Unknown Notes",
                       "现场版", "現場版", "混音版", "不插電", "翻唱", "伴奏", "純音樂", "剪輯版",
                       "国语版", "粵語版", "日文版", "重製版", "加速版"]
        for marker in markers {
            let title = "Paper Moon (" + marker + ")"
            let fixture = try track(title: title, duration: 200)
            XCTAssertEqual(try LRCLIBLookup.requests(track: fixture, consent: true).count, 2)
            XCTAssertEqual(try searchDecode([["trackName": "Paper Moon", "duration": 200]], for: fixture), .noMatch)
            let base = try track(title: "Paper Moon", duration: 200)
            XCTAssertEqual(try searchDecode([["trackName": title, "duration": 200]], for: base), .noMatch)
        }
        for title in [#"Paper Moon (From "Example Film (Live)")"#,
                      "纸月亮（电影《示例（混音版）》主题曲）",
                      #"Paper Moon (From "Example Film" Acoustic Version)"#,
                      #"Paper Moon (From "Example Film (Part II)")"#,
                      #"Paper Moon (From "Example Film”)"#,
                      "Paper Moon (From An Unquoted Film)"] {
            let fixture = try track(title: title, duration: 200)
            XCTAssertEqual(try LRCLIBLookup.requests(track: fixture, consent: true).count, 2)
            XCTAssertEqual(try searchDecode([["trackName": "Paper Moon", "duration": 200]], for: fixture), .noMatch)
        }
        let qualified = try track(title: #"Paper Moon (Live) (From "Example Film")"#, duration: 200)
        XCTAssertEqual(try searchDecode([["trackName": "Paper Moon", "duration": 200]], for: qualified), .noMatch)
    }

    func testStrongArtistDurationAndScriptGatesDoNotUseFuzzyServerOrder() throws {
        let fixture = try track(title: "纸月亮", duration: 200)
        let bad: [[String: Any]] = [["trackName": "纸月亮", "artistName": "Another Artist", "duration": 200],
                                    ["trackName": "纸月亮", "duration": 202.001],
                                    ["trackName": "纸月亮", "duration": 197.999],
                                    ["trackName": "紙月亮", "duration": 200],
                                    ["trackName": "Zhi Yue Liang", "duration": 200]]
        for record in bad { XCTAssertEqual(try searchDecode([record], for: fixture), .noMatch) }
        let boundaryDurations: [TimeInterval] = [198, 202]
        for duration in boundaryDurations {
            guard case .matched = try searchDecode([["trackName": "纸月亮", "duration": duration]], for: fixture) else {
                return XCTFail("Expected inclusive duration boundary")
            }
        }
    }

    func testAlbumPresentationRanksButExplicitRecordingChangesAreRejected() throws {
        for album in ["Amber Orbit (Live)", "Amber Orbit Remix", "Amber Orbit (Acoustic)",
                      "Amber Orbit (Instrumental)", "Amber Orbit (English Version)", "Amber Orbit 現場版"] {
            XCTAssertEqual(try searchDecode([["albumName": album]]), .noMatch)
        }
        let preferred: [String: Any] = ["id": 5, "albumName": "Amber Orbit (Deluxe Edition)",
                                        "syncedLyrics": NSNull(), "plainLyrics": "Preferred synthetic words"]
        let other: [String: Any] = ["id": 6, "albumName": "Different Collection"]
        for records in [[other, preferred], [preferred, other]] {
            guard case .matched(let result) = try searchDecode(records) else { return XCTFail("Expected unique album rank") }
            XCTAssertEqual(result.content, .plain(["Preferred synthetic words"]))
        }
    }

    func testTiedDifferentRecordingsStayAmbiguousInEitherOrderRegardlessOfTimingOrLyrics() throws {
        let first: [String: Any] = ["id": 7, "duration": 180, "syncedLyrics": NSNull(), "plainLyrics": NSNull()]
        let second: [String: Any] = ["id": 8, "duration": 181]
        for records in [[first, second], [second, first]] {
            assertError(.identityMismatch) { _ = try searchDecode(records) }
        }
        let differentText: [String: Any] = ["id": 9, "plainLyrics": "Different synthetic words"]
        assertError(.identityMismatch) { _ = try searchDecode([[:], differentText]) }
        let low1: [String: Any] = ["id": 10, "albumName": "Other", "duration": 180]
        let low2: [String: Any] = ["id": 11, "albumName": "Another", "duration": 181]
        for records in [[low1, low2, [:]], [[:], low1, low2]] {
            guard case .matched = try searchDecode(records) else { return XCTFail("Expected unique strongest rank") }
        }
    }

    func testIdenticalDuplicatesCollapseButConflictingIDsFailClosed() throws {
        guard case .matched = try searchDecode([[:], [:], ["id": 43]]) else {
            return XCTFail("Identical duplicate records should not create ambiguity")
        }
        assertError(.invalidResponse) { _ = try searchDecode([[:], ["duration": 181]]) }
        assertError(.invalidResponse) { _ = try searchDecode([["id": 0]]) }
        assertError(.invalidResponse) { _ = try searchDecode([["artistName": ""]]) }
    }

    func testSearchArraysAreBoundedAndMalformedSchemaIsNeverPartiallyAccepted() throws {
        let fixture = try track()
        let request = try XCTUnwrap(LRCLIBLookup.requests(track: fixture, consent: true).last)
        for payload in [Data("{".utf8), Data("null".utf8), try body(),
                        Data("[{}]".utf8), Data("[".utf8) + (try body()) + Data(",{}]".utf8)] {
            assertError(.invalidResponse) {
                _ = try LRCLIBLookup.decode(LyricsLookupResponse(url: request.url, statusCode: 200, body: payload),
                                            for: fixture, request: request)
            }
        }
        XCTAssertEqual(try searchDecode([]), .noMatch)
        guard case .matched = try searchDecode(Array(repeating: [:], count: LRCLIBLookup.maximumSearchResults - 1)) else {
            return XCTFail("Expected complete below-cap duplicate set")
        }
        for count in [LRCLIBLookup.maximumSearchResults, LRCLIBLookup.maximumSearchResults + 1] {
            assertError(.invalidResponse) { _ = try searchDecode(Array(repeating: [:], count: count)) }
        }
        assertError(.tooLarge) {
            _ = try LRCLIBLookup.decode(LyricsLookupResponse(url: request.url, statusCode: 200,
                                        body: Data(repeating: 32, count: LRCLIBLookup.maximumResponseBytes + 1)),
                                        for: fixture, request: request)
        }
        assertError(.tooLarge) {
            _ = try searchDecode([["plainLyrics": String(repeating: "a", count: LRCParser.maximumInputBytes + 1)]])
        }
    }

    func testSearchStatusIdentityAndResultStatesKeepTheSameStrictBoundary() throws {
        let fixture = try track(title: #"Paper Moon (From "Example Film")"#)
        let plan = try LRCLIBLookup.requests(track: fixture, consent: true)
        let originalSearch = plan[1]
        let normalizedSearch = plan[2]
        assertError(.requestNotAllowed) {
            _ = try LRCLIBLookup.decode(LyricsLookupResponse(url: normalizedSearch.url, statusCode: 200,
                                                            body: Data("[]".utf8)),
                                       for: fixture, request: originalSearch)
        }
        XCTAssertEqual(try searchDecode([["instrumental": true, "plainLyrics": NSNull(), "syncedLyrics": NSNull()]]),
                       .matched(.instrumental))
        XCTAssertEqual(try searchDecode([["plainLyrics": NSNull(), "syncedLyrics": NSNull()]]), .unavailable)
        assertError(.invalidResponse) { _ = try searchDecode([["instrumental": true]]) }
        assertError(.invalidLyrics) { _ = try searchDecode([["syncedLyrics": NSNull(), "plainLyrics": "[00:01]Timed"]]) }
    }

    func testEmbeddedTagsUseSelectedCandidateIdentityAndExplicitPlainOnly() throws {
        let fixture = try track(title: #"Paper Moon (From "Example Film")"#, duration: 200)
        let tags = "[ti:Paper Moon]\n[ar:Glass Orchard]\n[al:Amber Orbit (Deluxe Edition)]\n[00:01]Synthetic moon"
        let selected: [String: Any] = ["trackName": "Paper Moon", "albumName": "Amber Orbit (Deluxe Edition)",
                                       "duration": 201, "syncedLyrics": tags]
        guard case .matched = try searchDecode([selected], for: fixture) else { return XCTFail("Expected candidate tag match") }
        var conflicting = selected
        conflicting["syncedLyrics"] = "[al:Unrelated Album]\n[00:01]Synthetic moon"
        assertError(.identityMismatch) { _ = try searchDecode([conflicting], for: fixture) }
        var plain = selected
        plain["syncedLyrics"] = "No supplied timing"
        plain["plainLyrics"] = "Explicit plain synthetic words"
        guard case .matched(let result) = try searchDecode([plain], for: fixture) else { return XCTFail("Expected explicit plain") }
        XCTAssertEqual(result.content, .plain(["Explicit plain synthetic words"]))
        plain["plainLyrics"] = NSNull()
        assertError(.invalidLyrics) { _ = try searchDecode([plain], for: fixture) }
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

    func testSemanticFallbackIsSequentialSpacedAndBoundedToThreeDistinctRequests() async throws {
        let clock = FixtureClock()
        let fixture = try track(title: #"Paper Moon (From "Example Film")"#, duration: 200)
        let mock = SequenceTransport(replies: [.init(statusCode: 404), .init(body: Data("[]".utf8)),
                                               .init(body: try searchBody([["trackName": "Paper Moon", "duration": 201]]))],
                                     now: { clock.now() })
        let client = LyricsLookupClient(transport: mock, monotonicNow: { clock.now() }, wait: { clock.advance($0) })
        guard case .matched = try await client.lookup(track: fixture, consent: true) else { return XCTFail("Expected last-phase match") }
        let requests = await mock.requests
        let times = await mock.times
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map { $0.url }).count, 3)
        XCTAssertEqual(times[1] - times[0], 0.3, accuracy: 0.000_001)
        XCTAssertEqual(times[2] - times[1], 0.3, accuracy: 0.000_001)
    }

    func testAllNoMatchesFinishAndDuplicateSearchIsNotRepeated() async throws {
        for title in ["Paper Moon", #"Paper Moon (From "Example Film")"#] {
            let clock = FixtureClock()
            let mock = SequenceTransport(replies: [.init(statusCode: 404), .init(body: Data("[]".utf8)),
                                                   .init(body: Data("[]".utf8))])
            let client = LyricsLookupClient(transport: mock, monotonicNow: { clock.now() }, wait: { clock.advance($0) })
            let result = try await client.lookup(track: track(title: title), consent: true)
            XCTAssertEqual(result, .noMatch)
            let count = await mock.requests.count
            XCTAssertEqual(count, title == "Paper Moon" ? 2 : 3)
        }
    }

    func testExactIdentityMismatchCanSearchButEmbeddedConflictAndUnavailableCannot() async throws {
        let clock = FixtureClock()
        let fallback = SequenceTransport(replies: [.init(body: try body(["albumName": "Different Collection"])),
                                                   .init(body: try searchBody([[:]]))])
        let client = LyricsLookupClient(transport: fallback, monotonicNow: { clock.now() }, wait: { clock.advance($0) })
        guard case .matched = try await client.lookup(track: track(), consent: true) else { return XCTFail("Expected identity fallback") }
        let count = await fallback.requests.count
        XCTAssertEqual(count, 2)
        let conflict = SequenceTransport(replies: [.init(body: try body(["syncedLyrics": "[ti:Wrong Title]\n[00:01]Synthetic"]))])
        do { _ = try await LyricsLookupClient(transport: conflict).lookup(track: track(), consent: true); XCTFail("Expected embedded conflict") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .identityMismatch) }
        let conflictCount = await conflict.requests.count
        XCTAssertEqual(conflictCount, 1)
        let empty = SequenceTransport(replies: [.init(body: try body(["syncedLyrics": NSNull(), "plainLyrics": NSNull()]))])
        let emptyResult = try await LyricsLookupClient(transport: empty).lookup(track: track(), consent: true)
        XCTAssertEqual(emptyResult, .unavailable)
        let emptyCount = await empty.requests.count
        XCTAssertEqual(emptyCount, 1)
    }

    func testFallbackCannotEvadeServerCooldownAtAnyPhase() async throws {
        for phase in 0..<3 {
            for status in [429, 503] {
                let clock = FixtureClock()
                var replies: [FixtureReply] = [.init(statusCode: 404), .init(body: Data("[]".utf8))]
                replies = Array(replies.prefix(phase))
                replies.append(.init(statusCode: status, retryAfter: "90"))
                let mock = SequenceTransport(replies: replies)
                let client = LyricsLookupClient(transport: mock, monotonicNow: { clock.now() }, wait: { clock.advance($0) })
                let fixture = try track(title: #"Paper Moon (From "Example Film")"#)
                do { _ = try await client.lookup(track: fixture, consent: true); XCTFail("Expected provider cooldown") }
                catch {
                    let expected: LyricsLookupError = status == 429 ? .rateLimited(retryAfter: 90) : .serviceUnavailable(retryAfter: 90)
                    XCTAssertEqual(error as? LyricsLookupError, expected)
                }
                clock.advance(10)
                do { _ = try await client.lookup(track: track(title: "Different"), consent: true); XCTFail("Expected global cooldown") }
                catch {
                    guard let failure = error as? LyricsLookupError, case .rateLimited(let delay) = failure else {
                        return XCTFail("Expected cooldown")
                    }
                    XCTAssertEqual(delay, 80, accuracy: 0.000_001)
                }
                let count = await mock.requests.count
                XCTAssertEqual(count, phase + 1)
            }
        }
    }

    func testMalformedAmbiguousAndTransportFailuresDoNotAdvanceSearchPhase() async throws {
        let fixture = try track(title: #"Paper Moon (From "Example Film")"#, duration: 200)
        let failures: [(FixtureReply, LyricsLookupError)] = [
            (.init(body: Data("[{}]".utf8)), .invalidResponse),
            (.init(body: try searchBody([["id": 1, "trackName": "Paper Moon", "duration": 200],
                                         ["id": 2, "trackName": "Paper Moon", "duration": 201]])), .identityMismatch),
            (.init(failure: .offline), .offline), (.init(failure: .timedOut), .timedOut),
            (.init(failure: .transportFailure), .transportFailure)
        ]
        for (reply, expected) in failures {
            let clock = FixtureClock()
            let mock = SequenceTransport(replies: [.init(statusCode: 404), reply])
            let client = LyricsLookupClient(transport: mock, monotonicNow: { clock.now() }, wait: { clock.advance($0) })
            do { _ = try await client.lookup(track: fixture, consent: true); XCTFail("Expected terminal fallback error") }
            catch { XCTAssertEqual(error as? LyricsLookupError, expected) }
            let count = await mock.requests.count
            XCTAssertEqual(count, 2)
        }
    }

    func testSingleFlightIsHeldAndExternalCancellationWorksDuringFallbackGap() async throws {
        let gap = ControlledGap()
        let mock = SequenceTransport(replies: [.init(statusCode: 404)])
        let client = LyricsLookupClient(transport: mock, wait: { try await gap.suspend($0) })
        let fixture = try track()
        let pending = Task { try await client.lookup(track: fixture, consent: true) }
        do { try await gap.waitForEntry() }
        catch { pending.cancel(); throw error }
        do { _ = try await client.lookup(track: fixture, consent: true); XCTFail("Expected single flight across gap") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .busy) }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation during wait") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .cancelled) }
        let count = await mock.requests.count
        XCTAssertEqual(count, 1)
    }

    func testCancellationBetweenFallbackRequestsDoesNotStartAnotherFetch() async throws {
        let clock = FixtureClock()
        let mock = SequenceTransport(replies: [.init(statusCode: 404)])
        let client = LyricsLookupClient(transport: mock, monotonicNow: { clock.now() }, wait: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        })
        let task = Task { try await client.lookup(track: track(), consent: true) }
        do { _ = try await task.value; XCTFail("Expected cancellation during gap") }
        catch { XCTAssertEqual(error as? LyricsLookupError, .cancelled) }
        let count = await mock.requests.count
        XCTAssertEqual(count, 1)
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

private struct FixtureReply: Sendable {
    var statusCode: Int = 200
    var body = Data()
    var retryAfter: String? = nil
    var failure: LyricsLookupError? = nil
}

private actor SequenceTransport: LyricsLookupTransport {
    let replies: [FixtureReply]
    let now: @Sendable () -> TimeInterval
    private(set) var requests: [LyricsLookupRequest] = []
    private(set) var times: [TimeInterval] = []

    init(replies: [FixtureReply], now: @escaping @Sendable () -> TimeInterval = { 0 }) {
        self.replies = replies
        self.now = now
    }

    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        let index = requests.count
        requests.append(request)
        times.append(now())
        guard index < replies.count else { throw LyricsLookupError.invalidResponse }
        let reply = replies[index]
        if let failure = reply.failure { throw failure }
        return LyricsLookupResponse(url: request.url, statusCode: reply.statusCode,
                                    retryAfter: reply.retryAfter, body: reply.body)
    }
}

private actor ControlledGap {
    private var entered = false
    private enum FixtureFailure: Error { case waitDeadline }

    func suspend(_ seconds: TimeInterval) async throws {
        entered = true
        try await Task.sleep(nanoseconds: 30_000_000_000)
    }

    func waitForEntry() async throws {
        let deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2
        while !entered {
            guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else {
                throw FixtureFailure.waitDeadline
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
