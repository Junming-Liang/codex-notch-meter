import XCTest
@testable import NotchCore

/// All fixture text is synthetic and original; no provider, account, player or
/// network access is involved. These tests exercise whole-line timing only.
final class LyricsTests: XCTestCase {
    private func cues(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> [LyricCue] {
        let document = try LRCParser.parse(source)
        guard case .synchronized(let result) = document.content else {
            XCTFail("Expected synchronized fixture", file: file, line: line)
            return []
        }
        return result
    }

    private func assertParseError(_ source: String, _ expected: LRCParser.ParseError,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try LRCParser.parse(source), file: file, line: line) {
            XCTAssertEqual($0 as? LRCParser.ParseError, expected, file: file, line: line)
        }
    }

    private func timedDocument() throws -> LyricsDocument {
        try LRCParser.parse("[00:02]Paper comet wakes\n[00:04]\n[00:06]小小星舟 🌱\n[00:09]Amber orbit hums")
    }

    private func assertLine(_ selection: LyricsTimeline.Selection, _ expected: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case .line(_, let cue) = selection else {
            XCTFail("Expected a line, got \(selection)", file: file, line: line)
            return
        }
        XCTAssertEqual(cue.text, expected, file: file, line: line)
    }

    func testUnicodeBOMNewlinesAndFractionalTimestamps() throws {
        let result = try cues("\u{FEFF}[0:01]小小星舟 🌱\r\n[00:02.3]Café e\u{301}\r[00:03.45]ورق القمر\n[00:04.567]Paper comet")
        XCTAssertEqual(result.map(\.startTime), [1, 2.3, 3.45, 4.567])
        XCTAssertEqual(result.map(\.text), ["小小星舟 🌱", "Café e\u{301}", "ورق القمر", "Paper comet"])
    }

    func testMultipleTimestampsSortAndLastSourceDuplicateWins() throws {
        let result = try cues("[00:06][00:02][00:06]Paper comet\n[00:02]Amber orbit\n[00:06]\n[00:04]Glass cloud")
        XCTAssertEqual(result.map(\.startTime), [2, 4, 6])
        XCTAssertEqual(result.map(\.text), ["Amber orbit", "Glass cloud", ""])
    }

    func testOptionalMetadataAndLastValidGlobalOffset() throws {
        let document = try LRCParser.parse("[ti:First name]\n[AR:Fixture artist]\n[00:01.500]Paper comet\n[ti:Second name]\n[offset:+500]\n[offset:bad]\n[unknown:value]")
        XCTAssertEqual(document.metadata, ["ti": "Second name", "ar": "Fixture artist"])
        XCTAssertEqual(document.offsetMilliseconds, 500)
        XCTAssertEqual(document.ignoredLineCount, 2)
        guard case .synchronized(let result) = document.content else { return XCTFail("Expected cues") }
        XCTAssertEqual(result.first?.startTime, 1)
        XCTAssertEqual(try cues("[offset:-250]\n[00:01.500]Paper comet").first?.startTime, 1.75)
    }

    func testPositiveOffsetPreservesAlreadyStartedNegativeCues() throws {
        let source = "[00:01]Early paper\n[00:02]Later paper\n[offset:3000]"
        XCTAssertEqual(try cues(source).map(\.startTime), [-2, -1])
        var timeline = LyricsTimeline()
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try LRCParser.parse(source), at: 10))
        XCTAssertTrue(timeline.update(generation: generation, position: 0, isPlaying: false, sampledAt: 10, now: 10))
        assertLine(timeline.selection(at: 10), "Later paper")
    }

    func testInvalidOffsetsNeverOverrideAValidOffset() throws {
        let invalid = ["", "+", "--1", "1.5", "NaN", "Infinity", "86400001", "999999999999999999999999", "١٢"]
        let source = "[offset:25]\n[00:01]Paper\n" + invalid.map { "[offset:\($0)]" }.joined(separator: "\n")
        let document = try LRCParser.parse(source)
        XCTAssertEqual(document.offsetMilliseconds, 25)
        XCTAssertEqual(document.ignoredLineCount, invalid.count)
        XCTAssertEqual(try cues("[offset:86400000]\n[1440:00]Paper").first?.startTime, 0)
    }

    func testPlainUnavailableAndInstrumentalAreDistinct() throws {
        XCTAssertEqual(try LRCParser.parse("Paper comet\n小小星舟\n[Chorus]").content,
                       .plain(["Paper comet", "小小星舟", "[Chorus]"]))
        XCTAssertEqual(try LRCParser.parse("[Instrumental]").content, .plain(["[Instrumental]"]))
        XCTAssertEqual(try LRCParser.parse(" \n\t\n[ti:Only a title]").content, .unavailable)
        XCTAssertEqual(LyricsDocument.instrumental.content, .instrumental)
        XCTAssertNotEqual(LyricsDocument.instrumental, .unavailable)
    }

    func testMalformedAndInvalidTimesCannotBecomeSynchronizedOrPlainLyrics() throws {
        let invalid = ["[-00:01]", "[+00:01]", "[00:60]", "[1:2]", "[00:01.]", "[00:01.1234]",
                       "[00:01:02]", "[1440:00.001]", "[99999:00]", "[00:NaN]", "[NaN:00]",
                       "[٠٠:٠١]", "[00:01", "[00:01][00:70]"]
        let document = try LRCParser.parse(invalid.map { $0 + "Broken fixture" }.joined(separator: "\n"))
        XCTAssertEqual(document.content, .unavailable)
        XCTAssertEqual(document.ignoredLineCount, invalid.count)
        XCTAssertEqual(try cues("[00:00]Start\n[1440:00]Day boundary").map(\.startTime), [0, 86_400])
    }

    func testMixedUntimedLinesAreReportedRatherThanAssignedInventedTimes() throws {
        let document = try LRCParser.parse("An untimed preface\n[00:02]Paper comet\nAnother untimed line")
        XCTAssertEqual(document.ignoredLineCount, 2)
        guard case .synchronized(let result) = document.content else { return XCTFail("Expected cue") }
        XCTAssertEqual(result, [LyricCue(startTime: 2, text: "Paper comet")])
    }

    func testEnhancedTokensStayLiteralWithoutWordTiming() throws {
        XCTAssertEqual(try cues("[00:02]<00:02.100>Paper <00:02.900>comet").first?.text,
                       "<00:02.100>Paper <00:02.900>comet")
    }

    func testInputByteLimitAcceptsBoundaryAndRejectsOverflow() throws {
        let boundary = String(repeating: String(repeating: " ", count: 4_095) + "\n", count: 64)
        XCTAssertEqual(boundary.utf8.count, LRCParser.maximumInputBytes)
        XCTAssertEqual(try LRCParser.parse(boundary).content, .unavailable)
        assertParseError(boundary + " ", .inputTooLarge)
    }

    func testPhysicalLineLimitIncludesEmptyAndTrailingLines() throws {
        XCTAssertEqual(try LRCParser.parse(String(repeating: "\n", count: LRCParser.maximumLines - 1)).content, .unavailable)
        assertParseError(String(repeating: "\n", count: LRCParser.maximumLines), .tooManyLines)
    }

    func testRawLineLimitIsCheckedBeforeTrimming() throws {
        XCTAssertEqual(try LRCParser.parse(String(repeating: " ", count: LRCParser.maximumLineBytes)).content, .unavailable)
        assertParseError(String(repeating: " ", count: LRCParser.maximumLineBytes + 1), .lineTooLong(line: 1))
    }

    func testCueAndPlainTextLimitsCountUTF8Bytes() throws {
        let boundary = String(repeating: "🌱", count: LRCParser.maximumTextBytes / 4)
        XCTAssertEqual(try cues("[00:01]" + boundary).first?.text, boundary)
        assertParseError("[00:01]" + boundary + "a", .textTooLong(line: 1))
        XCTAssertEqual(try LRCParser.parse(boundary).content, .plain([boundary]))
        assertParseError(boundary + "a", .textTooLong(line: 1))
    }

    func testMetadataLimitDoesNotTruncateValues() throws {
        let boundary = String(repeating: "a", count: LRCParser.maximumMetadataBytes)
        XCTAssertEqual(try LRCParser.parse("[ti:\(boundary)]").metadata["ti"], boundary)
        assertParseError("[ti:\(boundary)a]", .metadataTooLong(line: 1))
    }

    func testPerLineTimestampLimitAppliesBeforeDeduplication() throws {
        let boundary = String(repeating: "[00:01]", count: LRCParser.maximumTimestampsPerLine)
        XCTAssertEqual(try cues(boundary + "Paper").count, 1)
        assertParseError(boundary + "[00:01]Paper", .tooManyTimestamps(line: 1))
    }

    func testTotalCueLimitAppliesBeforeDeduplication() throws {
        let line = String(repeating: "[00:01]", count: LRCParser.maximumTimestampsPerLine) + "Paper"
        let boundary = Array(repeating: line, count: LRCParser.maximumCues / LRCParser.maximumTimestampsPerLine)
            .joined(separator: "\n")
        XCTAssertEqual(try cues(boundary).count, 1)
        assertParseError(boundary + "\n[00:01]Paper", .tooManyCues)
    }

    func testBeforeFirstExactBoundariesExplicitGapsAndFinalHold() throws {
        var timeline = LyricsTimeline(freshnessInterval: 30)
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 100))
        XCTAssertEqual(timeline.selection(at: 100), .waitingForPlayback)
        XCTAssertTrue(timeline.update(generation: generation, position: 0, isPlaying: true, sampledAt: 100, now: 100))
        XCTAssertEqual(timeline.selection(at: 101.999), .beforeFirstLine)
        assertLine(timeline.selection(at: 102), "Paper comet wakes")
        assertLine(timeline.selection(at: 103.999), "Paper comet wakes")
        XCTAssertEqual(timeline.selection(at: 104), .gap)
        XCTAssertEqual(timeline.selection(at: 105.999), .gap)
        assertLine(timeline.selection(at: 106), "小小星舟 🌱")
        assertLine(timeline.selection(at: 120), "Amber orbit hums")
    }

    func testKnownDurationEndsAtExactBoundary() throws {
        var timeline = LyricsTimeline(freshnessInterval: 30)
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 0))
        XCTAssertTrue(timeline.update(generation: generation, position: 9, isPlaying: true,
                                      duration: 12, sampledAt: 0, now: 0))
        assertLine(timeline.selection(at: 2.999), "Amber orbit hums")
        XCTAssertEqual(timeline.selection(at: 3), .ended)
    }

    func testSeekForwardAndBackwardReanchorImmediately() throws {
        var timeline = LyricsTimeline()
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 10))
        XCTAssertTrue(timeline.update(generation: generation, position: 2, isPlaying: false, sampledAt: 10, now: 10))
        assertLine(timeline.selection(at: 10), "Paper comet wakes")
        XCTAssertTrue(timeline.update(generation: generation, position: 10, isPlaying: false, sampledAt: 11, now: 11))
        assertLine(timeline.selection(at: 11), "Amber orbit hums")
        XCTAssertTrue(timeline.update(generation: generation, position: 3, isPlaying: false, sampledAt: 12, now: 12))
        assertLine(timeline.selection(at: 12), "Paper comet wakes")
        XCTAssertTrue(timeline.update(generation: generation, position: 0, isPlaying: false, sampledAt: 13, now: 13))
        XCTAssertEqual(timeline.selection(at: 13), .beforeFirstLine)
    }

    func testPauseHoldsAndResumeUsesOnlyNewMonotonicElapsedTime() throws {
        var timeline = LyricsTimeline(freshnessInterval: 30)
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 100))
        XCTAssertTrue(timeline.update(generation: generation, position: 2, isPlaying: true, sampledAt: 100, now: 100))
        assertLine(timeline.selection(at: 101), "Paper comet wakes")
        XCTAssertTrue(timeline.update(generation: generation, position: 3, isPlaying: false, sampledAt: 101, now: 101))
        assertLine(timeline.selection(at: 110), "Paper comet wakes")
        XCTAssertTrue(timeline.update(generation: generation, position: 3, isPlaying: true, sampledAt: 110, now: 110))
        XCTAssertEqual(timeline.selection(at: 111), .gap)
        assertLine(timeline.selection(at: 113), "小小星舟 🌱")
    }

    func testTransportLatencyProjectsFromObservationRatherThanReceipt() throws {
        var timeline = LyricsTimeline()
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 100))
        XCTAssertTrue(timeline.update(generation: generation, position: 2, isPlaying: true, sampledAt: 100, now: 102))
        XCTAssertEqual(timeline.selection(at: 102), .gap)
    }

    func testRenderPollingCannotRefreshPausedOrPlayingSourceAge() throws {
        for isPlaying in [false, true] {
            var timeline = LyricsTimeline()
            let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 100))
            XCTAssertTrue(timeline.update(generation: generation, position: 9, isPlaying: isPlaying,
                                          sampledAt: 100, now: 100))
            let freshTimes: [TimeInterval] = [101, 102, 103, 104, 104.999]
            for now in freshTimes { assertLine(timeline.selection(at: now), "Amber orbit hums") }
            XCTAssertEqual(timeline.selection(at: 105), .stale)
            XCTAssertEqual(timeline.selection(at: 110), .stale)
            XCTAssertFalse(timeline.update(generation: generation, position: 2, isPlaying: isPlaying,
                                           sampledAt: 105, now: 110))
            XCTAssertEqual(timeline.selection(at: 110), .stale)
            XCTAssertTrue(timeline.update(generation: generation, position: 2, isPlaying: false,
                                          sampledAt: 110, now: 110))
            assertLine(timeline.selection(at: 110), "Paper comet wakes")
        }
    }

    func testTrackReplacementRejectsOldPlaybackAndAsyncLyrics() throws {
        var timeline = LyricsTimeline()
        let first = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 10))
        XCTAssertTrue(timeline.update(generation: first, position: 6, isPlaying: false, sampledAt: 10, now: 10))
        let second = try XCTUnwrap(timeline.replaceTrack(at: 11))
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(timeline.selection(at: 11), .unavailable)
        XCTAssertFalse(timeline.setLyrics(try timedDocument(), generation: first))
        XCTAssertFalse(timeline.update(generation: first, position: 6, isPlaying: true, sampledAt: 12, now: 12))
        XCTAssertTrue(timeline.setLyrics(try timedDocument(), generation: second))
        XCTAssertEqual(timeline.selection(at: 11), .waitingForPlayback)
        XCTAssertFalse(timeline.update(generation: second, position: 6, isPlaying: false, sampledAt: 10, now: 11))
        XCTAssertTrue(timeline.update(generation: second, position: 0, isPlaying: true, sampledAt: 11, now: 11))
        XCTAssertEqual(timeline.selection(at: 11), .beforeFirstLine)
    }

    func testReplayedOutOfOrderFutureAndNonfiniteSamplesDoNotChangeAnchor() throws {
        var timeline = LyricsTimeline()
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 10))
        XCTAssertTrue(timeline.update(generation: generation, position: 2, isPlaying: false, sampledAt: 11, now: 11))
        let invalidSampleTimes: [TimeInterval] = [10, 11, 13, .nan, .infinity, -.infinity]
        for sampledAt in invalidSampleTimes {
            XCTAssertFalse(timeline.update(generation: generation, position: 9, isPlaying: true,
                                           sampledAt: sampledAt, now: 12))
        }
        let invalidPositions: [TimeInterval] = [-1, 86_401, .nan, .infinity, -.infinity]
        for position in invalidPositions {
            XCTAssertFalse(timeline.update(generation: generation, position: position, isPlaying: true,
                                           sampledAt: 12, now: 12))
        }
        let invalidDurations: [TimeInterval] = [-1, 0, 86_401, .nan, .infinity, -.infinity]
        for duration in invalidDurations {
            XCTAssertFalse(timeline.update(generation: generation, position: 9, isPlaying: true,
                                           duration: duration, sampledAt: 12, now: 12))
        }
        assertLine(timeline.selection(at: 12), "Paper comet wakes")
    }

    func testInvalidAndBackwardClockCannotRewindOrPoisonState() throws {
        var timeline = LyricsTimeline()
        let generation = try XCTUnwrap(timeline.replaceTrack(with: try timedDocument(), at: 10))
        XCTAssertTrue(timeline.update(generation: generation, position: 2, isPlaying: true, sampledAt: 10, now: 10))
        XCTAssertEqual(timeline.selection(at: 12), .gap)
        let invalidClocks: [TimeInterval] = [-1, 10, 11.999, .nan, .infinity, -.infinity]
        for now in invalidClocks {
            XCTAssertEqual(timeline.selection(at: now), .stale)
            XCTAssertNil(timeline.replaceTrack(at: now))
            XCTAssertFalse(timeline.update(generation: generation, position: 9, isPlaying: true, sampledAt: 12, now: now))
        }
        XCTAssertEqual(timeline.generation, generation)
        XCTAssertEqual(timeline.selection(at: 12), .gap)
        assertLine(timeline.selection(at: 14), "小小星舟 🌱")
    }

    func testNontimedContentNeverPretendsToBeAnActiveTimedLine() throws {
        var timeline = LyricsTimeline()
        XCTAssertEqual(timeline.selection(at: 0), .unavailable)
        XCTAssertFalse(timeline.setLyrics(.instrumental, generation: 0))
        XCTAssertFalse(timeline.update(generation: 0, position: 0, isPlaying: true, sampledAt: 0, now: 0))
        let plain = try XCTUnwrap(timeline.replaceTrack(with: try LRCParser.parse("Paper comet"), at: 1))
        XCTAssertEqual(timeline.selection(at: 1), .waitingForPlayback)
        XCTAssertTrue(timeline.update(generation: plain, position: 0, isPlaying: false, sampledAt: 1, now: 1))
        XCTAssertEqual(timeline.selection(at: 1), .plain(["Paper comet"]))
        let instrumental = try XCTUnwrap(timeline.replaceTrack(with: .instrumental, at: 2))
        XCTAssertEqual(timeline.selection(at: 2), .waitingForPlayback)
        XCTAssertTrue(timeline.update(generation: instrumental, position: 0, isPlaying: false, sampledAt: 2, now: 2))
        XCTAssertEqual(timeline.selection(at: 2), .instrumental)
    }

    func testPlainAndInstrumentalContentExpiresWhenPlaybackSourceIsLost() throws {
        let fixtures: [(LyricsDocument, LyricsTimeline.Selection)] = [
            (try LRCParser.parse("Paper comet"), .plain(["Paper comet"])),
            (.instrumental, .instrumental)
        ]
        for (document, expected) in fixtures {
            for isPlaying in [false, true] {
                var timeline = LyricsTimeline()
                let generation = try XCTUnwrap(timeline.replaceTrack(with: document, at: 10))
                XCTAssertEqual(timeline.selection(at: 10), .waitingForPlayback)
                XCTAssertTrue(timeline.update(generation: generation, position: 0, isPlaying: isPlaying,
                                              sampledAt: 10, now: 10))
                XCTAssertEqual(timeline.selection(at: 10), expected)
                XCTAssertEqual(timeline.selection(at: 14.999), expected)
                XCTAssertEqual(timeline.selection(at: 15), .stale)
                XCTAssertEqual(timeline.selection(at: 20), .stale)
                XCTAssertFalse(timeline.update(generation: generation, position: 0, isPlaying: isPlaying,
                                               sampledAt: 15, now: 20))
                XCTAssertEqual(timeline.selection(at: 20), .stale)
                XCTAssertTrue(timeline.update(generation: generation, position: 0, isPlaying: isPlaying,
                                              sampledAt: 20, now: 20))
                XCTAssertEqual(timeline.selection(at: 20), expected)
            }
        }
    }

    func testFreshnessConfigurationIsFinitePositiveAndBounded() {
        let invalidIntervals: [TimeInterval] = [-1, 0, .nan, .infinity, -.infinity]
        for invalid in invalidIntervals {
            XCTAssertEqual(LyricsTimeline(freshnessInterval: invalid).freshnessInterval, 5)
        }
        XCTAssertEqual(LyricsTimeline(freshnessInterval: 0.5).freshnessInterval, 0.5)
        XCTAssertEqual(LyricsTimeline(freshnessInterval: 31).freshnessInterval, 30)
    }
}
