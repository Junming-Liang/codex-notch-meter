#if os(macOS)
import Foundation
import XCTest
@testable import CodexNotchMeter
import NotchCore

/// Runs the production controller and its real polling loop with invented,
/// in-memory boundaries. No Music process, file import, settings or network use.
@MainActor
final class MusicLookupRecoveryTests: XCTestCase {
    private func makeController(reader: FixtureReader, lookup: FixtureLookup,
                                clock: FixtureClock = FixtureClock()) -> MusicLyricsController {
        let controller = MusicLyricsController(synthetic: true, reader: reader,
            lookup: { track, consent in
                XCTAssertTrue(consent)
                return try await lookup.lookup(track)
            }, clock: { clock.now })
        controller.setOnlineLookupEnabled(true)
        controller.setEnabled(true)
        controller.start()
        return controller
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 7,
                           condition: @escaping @MainActor () async -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out: \(description)")
        throw FixtureFailure.timeout
    }

    func testRepeatedLocalDeferralsDoNotExhaustAttemptsOrStartGlobalBackoff() async throws {
        let clock = FixtureClock()
        let busyReader = FixtureReader(title: "Busy Orbit", clock: clock)
        let spacingReader = FixtureReader(title: "Spaced Orbit", clock: clock)
        let busyLookup = FixtureLookup(plans: ["Busy Orbit": Array(repeating: .failure(.busy), count: 4) + [.lyrics("Busy recovered")]])
        let spacingLookup = FixtureLookup(plans: ["Spaced Orbit": Array(repeating: .failure(.deferred(retryAfter: 0.3)), count: 4) + [.lyrics("Spacing recovered")]])
        let busy = makeController(reader: busyReader, lookup: busyLookup, clock: clock)
        let spacing = makeController(reader: spacingReader, lookup: spacingLookup, clock: clock)
        defer { busy.stop(); spacing.stop() }

        try await waitUntil("both local waits are shown without claiming a service outage") {
            busy.lookupState == .waitingForProvider && spacing.lookupState == .waitingForProvider
        }
        XCTAssertFalse(busy.isPlayingForPresentation)
        XCTAssertFalse(spacing.isPlayingForPresentation)
        try await waitUntil("more than three local deferrals recover on ordinary polls", timeout: 8) {
            busy.line == "Busy recovered" && spacing.line == "Spacing recovered"
        }
        XCTAssertEqual(busy.lookupState, .matched)
        XCTAssertEqual(spacing.lookupState, .matched)
        XCTAssertTrue(busy.isPlayingForPresentation)
        XCTAssertTrue(spacing.isPlayingForPresentation)
        let busyCalls = await busyLookup.calls
        let spacingCalls = await spacingLookup.calls
        XCTAssertEqual(busyCalls, Array(repeating: "Busy Orbit", count: 5))
        XCTAssertEqual(spacingCalls, Array(repeating: "Spaced Orbit", count: 5))
    }

    func testTrackChangeRetiresLocalWaitAndRejectsLatePreviousTrackResult() async throws {
        let clock = FixtureClock()
        let reader = FixtureReader(title: "Waiting Orbit", clock: clock)
        let lookup = FixtureLookup(plans: [
            "Waiting Orbit": [.failure(.deferred(retryAfter: 10))],
            "Held Orbit": [.held],
            "Current Orbit": [.lyrics("Current cue")]
        ])
        addTeardownBlock { await lookup.releaseHeld(with: "Retired fixture") }
        let controller = makeController(reader: reader, lookup: lookup, clock: clock)
        defer { controller.stop() }
        try await waitUntil("first track waits for its local provider") { controller.lookupState == .waitingForProvider }

        await reader.changeTrack(to: "Held Orbit")
        try await waitUntil("next track starts before the previous track's ten-second local wait") {
            await lookup.hasHeldResult
        }
        XCTAssertEqual(controller.trackTitle, "Held Orbit")
        XCTAssertTrue(controller.line.isEmpty)
        await reader.changeTrack(to: "Current Orbit")
        try await waitUntil("new track receives only its own lyric") { controller.line == "Current cue" }
        XCTAssertEqual(controller.trackTitle, "Current Orbit")
        await lookup.releaseHeld(with: "Obsolete cue")
        try await waitUntil("retired lookup actually returns its late result") { await lookup.returnedHeld }
        // Allow the real controller's resumed task to pass its cancellation and
        // generation guards; a new ordinary poll also must not resurrect it.
        let initialReads = await reader.readCount
        try await waitUntil("a fresh ordinary playback sample follows the late result") {
            await reader.readCount > initialReads
        }
        XCTAssertEqual(controller.line, "Current cue")
        XCTAssertEqual(controller.trackTitle, "Current Orbit")
        XCTAssertEqual(controller.lookupState, .matched)
        let calls = await lookup.calls
        XCTAssertEqual(calls, ["Waiting Orbit", "Held Orbit", "Current Orbit"])
    }

    func testTruncatedSearchDoesNotBlockNextTrack() async throws {
        let clock = FixtureClock()
        let reader = FixtureReader(title: "Crowded Orbit", clock: clock)
        let lookup = FixtureLookup(plans: [
            "Crowded Orbit": [.failure(.searchResultsTruncated)],
            "Unique Orbit": [.lyrics("Unique cue")]
        ])
        let controller = makeController(reader: reader, lookup: lookup, clock: clock)
        defer { controller.stop() }
        try await waitUntil("full search result has its honest terminal state") {
            controller.lookupState == .searchResultsTruncated
        }
        XCTAssertTrue(controller.line.isEmpty)
        let initialReads = await reader.readCount
        try await waitUntil("ordinary playback poll does not repeat the truncated lookup") {
            await reader.readCount > initialReads
        }
        let callsBeforeChange = await lookup.calls
        XCTAssertEqual(callsBeforeChange, ["Crowded Orbit"])
        await reader.changeTrack(to: "Unique Orbit")
        try await waitUntil("next track matches without a thirty-second cooldown") { controller.line == "Unique cue" }
        XCTAssertEqual(controller.lookupState, .matched)
        let calls = await lookup.calls
        XCTAssertEqual(calls, ["Crowded Orbit", "Unique Orbit"])
    }

    func testProviderCooldownLeavesTheOtherSourceAvailableAfterTrackChange() async throws {
        for failingPrimary in [true, false] {
            let clock = FixtureClock()
            let reader = FixtureReader(title: "Unavailable Orbit", clock: clock)
            let primaryTransport = FixtureTransport(source: .primary, responses: [
                "Unavailable Orbit": failingPrimary ? .status(503) : .noMatch,
                "Later Orbit": .lyrics("Primary cue")
            ])
            let fallbackTransport = FixtureTransport(source: .fallback, responses: [
                "Unavailable Orbit": failingPrimary ? .noMatch : .status(503),
                "Later Orbit": .lyrics("Fallback cue")
            ])
            let primary = LyricsLookupClient(transport: primaryTransport, monotonicNow: { clock.now })
            let fallback = AMLLLyricsClient(transport: fallbackTransport, now: { clock.now })
            let controller = MusicLyricsController(synthetic: true, reader: reader,
                lookup: { track, consent in try await primary.lookup(track: track, consent: consent) },
                amllLookup: { track, consent in try await fallback.lookup(track: track, consent: consent) },
                clock: { clock.now })
            defer { controller.stop() }
            controller.setOnlineLookupEnabled(true)
            controller.setAMLLFallbackEnabled(true)
            controller.setEnabled(true)
            controller.start()
            try await waitUntil("the real clients report a source's HTTP 503") {
                controller.lookupState == .serviceUnavailable
            }
            let initialReads = await reader.readCount
            try await waitUntil("two ordinary same-track polls keep the retry schedule") {
                await reader.readCount >= initialReads + 2
            }
            let primaryBeforeChange = await primaryTransport.calls
            let fallbackBeforeChange = await fallbackTransport.calls
            XCTAssertEqual(primaryBeforeChange, Array(repeating: "Unavailable Orbit", count: failingPrimary ? 1 : 2))
            XCTAssertEqual(fallbackBeforeChange, ["Unavailable Orbit"])
            XCTAssertTrue(controller.line.isEmpty)

            await reader.changeTrack(to: "Later Orbit")
            let expectedCue = failingPrimary ? "Fallback cue" : "Primary cue"
            try await waitUntil("the other source serves the new track during the failed source's cooldown") {
                controller.line == expectedCue
            }
            XCTAssertEqual(controller.sourceLabel, failingPrimary ? "AMLL 社区歌词" : "LRCLIB 社区歌词")
            XCTAssertEqual(controller.lookupState, .matched)
            let primaryAfterChange = await primaryTransport.calls
            let fallbackAfterChange = await fallbackTransport.calls
            XCTAssertEqual(primaryAfterChange, failingPrimary ? ["Unavailable Orbit"] :
                ["Unavailable Orbit", "Unavailable Orbit", "Later Orbit"])
            XCTAssertEqual(fallbackAfterChange, failingPrimary ? ["Unavailable Orbit", "Later Orbit"] : ["Unavailable Orbit"])

            // Even an explicit new-track call cannot bypass the actual failed
            // client's Retry-After. This checks transport traffic, not merely a
            // controller state or a mock closure throwing the expected error.
            let probe = try LyricsLookupTrack(title: "Cooldown Probe", artist: "Synthetic Orchard",
                album: "Test Constellation", duration: 180)
            do {
                if failingPrimary { _ = try await primary.lookup(track: probe, consent: true) }
                else { _ = try await fallback.lookup(track: probe, consent: true) }
                XCTFail("The failed source's Retry-After must survive a new song")
            } catch let error as LyricsLookupError {
                guard case .rateLimited(let remaining) = error else {
                    XCTFail("Expected the client's real cooldown, received \(error)")
                    continue
                }
                XCTAssertGreaterThan(remaining, 0)
                XCTAssertLessThanOrEqual(remaining, 60)
            }
            let primaryAfterProbe = await primaryTransport.calls
            let fallbackAfterProbe = await fallbackTransport.calls
            XCTAssertEqual(primaryAfterProbe, primaryAfterChange)
            XCTAssertEqual(fallbackAfterProbe, fallbackAfterChange)
        }
    }

}

private enum FixtureFailure: Error { case timeout, unexpectedLookup }

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime
    }
}

private actor FixtureReader: MusicSnapshotProvider {
    private var title: String
    private let clock: FixtureClock
    private(set) var readCount = 0
    init(title: String, clock: FixtureClock) { self.title = title; self.clock = clock }
    func changeTrack(to title: String) { self.title = title }
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        readCount += 1
        let track = MusicTrackIdentity(title: title, artist: "Synthetic Orchard", album: "Test Constellation", duration: 180)!
        return .snapshot(MusicPlaybackSnapshot(track: track, state: .playing, position: 12, observedAt: clock.now)!)
    }
}

private actor FixtureLookup {
    enum Outcome: Sendable {
        case failure(LyricsLookupError)
        case lyrics(String)
        case held
    }
    private var plans: [String: [Outcome]]
    private var held: CheckedContinuation<String, Never>?
    private(set) var calls: [String] = []
    private(set) var returnedHeld = false
    var hasHeldResult: Bool { held != nil }
    init(plans: [String: [Outcome]]) { self.plans = plans }
    func lookup(_ track: LyricsLookupTrack) async throws -> LyricsLookupResult {
        calls.append(track.title)
        guard var plan = plans[track.title], !plan.isEmpty else { throw FixtureFailure.unexpectedLookup }
        let outcome = plan.removeFirst()
        plans[track.title] = plan
        let cue: String
        switch outcome {
        case .failure(let error): throw error
        case .lyrics(let text): cue = text
        case .held:
            // Deliberately uncooperative cancellation exercises the controller's
            // late-result rejection rather than relying on a cooperative mock.
            cue = await withCheckedContinuation { held = $0 }
            returnedHeld = true
        }
        return .matched(try LRCParser.parse("[00:00]\(cue)"))
    }
    func releaseHeld(with text: String) {
        let continuation = held
        held = nil
        continuation?.resume(returning: text)
    }
}

private actor FixtureTransport: LyricsLookupTransport {
    enum Source: Equatable, Sendable { case primary, fallback }
    enum Response: Sendable { case status(Int), noMatch, lyrics(String) }
    let source: Source
    let responses: [String: Response]
    private(set) var calls: [String] = []
    init(source: Source, responses: [String: Response]) { self.source = source; self.responses = responses }
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let title = query.first(where: { $0.name == "track_name" })?.value,
              let response = responses[title] else { throw FixtureFailure.unexpectedLookup }
        calls.append(title)
        switch response {
        case .status(let status):
            return LyricsLookupResponse(url: request.url, statusCode: status, retryAfter: "60", body: Data())
        case .noMatch:
            return LyricsLookupResponse(url: request.url, statusCode: request.url.path == "/api/get" ? 404 : 200,
                body: Data("[]".utf8))
        case .lyrics(let cue):
            let record: [String: Any] = ["id": 1, "trackName": title, "artistName": "Synthetic Orchard",
                "albumName": "Test Constellation", "duration": source == .primary ? 180 : 0,
                "instrumental": false, "syncedLyrics": "[00:00]\(cue)", "plainLyrics": NSNull()]
            let payload: Any = request.url.path == "/api/get" ? record : [record]
            return LyricsLookupResponse(url: request.url, statusCode: 200,
                body: try JSONSerialization.data(withJSONObject: payload))
        }
    }
}

#endif
