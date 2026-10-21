#if os(macOS)
import AppKit
import NotchCore

/// Independent synthetic-input test of the real controller's instrumentation.
/// No Music IPC, account refresh, real files, screenshots, or global cursor
/// movement. This proves capture wiring, not field jitter or compositor timing.
@MainActor
final class DebugCaptureChecks {
    private struct Failure: Error { let label: String }
    private let completion: (Bool) -> Void
    private var task: Task<Void, Never>?
    private var panel: IslandPanelController?
    private var music: MusicLyricsController?
    private var capture: DebugCaptureController?
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    func stop() {
        task?.cancel(); task = nil
        capture?.stop(); panel?.stop(); music?.stop()
        capture = nil; panel = nil; music = nil
    }
    func start() {
        guard CommandLine.arguments.contains("--music-test"),
              CommandLine.arguments.contains("--debug-capture-test") else { completion(false); return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
                print("DEBUG_CAPTURE_OK: realController=true syntheticInput=true physicalJitterVerified=false")
                self.stop(); self.completion(true)
            } catch {
                print("DEBUG_CAPTURE_FAILED: \((error as? Failure)?.label ?? "fixture")")
                self.stop(); self.completion(false)
            }
        }
    }
    private func require(_ value: Bool, _ label: String) throws { if !value { throw Failure(label: label) } }
    private func until(_ label: String, _ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 4
        while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < end {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(label: label)
    }
    private func run() async throws {
        guard let screen = NSScreen.main,
              let track = MusicTrackIdentity(title: "PRIVATE_SONG_SENTINEL", artist: "PRIVATE_ARTIST_SENTINEL",
                    album: "PRIVATE_ALBUM_SENTINEL", duration: 120) else { throw Failure(label: "fixture") }
        let document = try LRCParser.parse("[00:00]PRIVATE_LYRICS_SENTINEL\n[00:40]PRIVATE_NEXT_SENTINEL")
        let music = MusicLyricsController(synthetic: true, reader: DebugCaptureReader(track: track), importer: { _ in document })
        self.music = music
        let model = MeterModel(demo: true, music: music), capture = model.debugCapture
        self.capture = capture
        try require(!capture.isRecording && !capture.hasScheduledDeadline, "default-off-no-deadline")
        let s = screen.frame
        guard let notch = NotchGeometry.calculate(screen: s, topInset: 32,
            auxiliaryLeft: CGRect(x: s.minX, y: s.maxY - 32, width: s.width / 2 - 110, height: 32),
            auxiliaryRight: CGRect(x: s.midX + 110, y: s.maxY - 32, width: s.width / 2 - 110, height: 32)) else {
            throw Failure(label: "geometry")
        }
        capture.start()
        let panel = IslandPanelController(model: model,
            geometry: IslandGeometry(notch: notch, screen: s, backingScale: screen.backingScaleFactor),
            startPolling: false, reducedMotionOverride: true, hovered: {}, refresh: {}, settings: {}, quit: {})
        self.panel = panel
        // Diagnostics are independent of Music enablement or playback.
        let silentNow = ProcessInfo.processInfo.systemUptime
        panel.smokePointer(inside: true, now: silentNow)
        panel.smokePointer(inside: true, now: silentNow + 0.14)
        panel.smokePointer(inside: false, now: silentNow + 0.4)
        panel.smokePointer(inside: false, now: silentNow + 0.64)
        capture.stop()
        try require(!music.enabled && !capture.hasScheduledDeadline && !(try capture.recorder.exportData()).isEmpty,
                    "no-music-capture-export")
        let previousSession = capture.recorder.sessionID
        capture.start()
        try require(previousSession != capture.recorder.sessionID && capture.recorder.storedEvents == 0,
                    "restart-clears-session")
        panel.recordDebugSnapshot()
        music.start(); music.setEnabled(true)
        try await until("fresh-source") { music.importSelectionToken != nil }
        guard let token = music.importSelectionToken else { throw Failure(label: "import-token") }
        music.importLyrics(from: URL(fileURLWithPath: "/synthetic-capture-fixture.lrc"), for: token)
        try await until("lyrics-ready") { music.isPlayingForPresentation }
        music.selectLyricsMode(true)
        try await until("music-owner") { panel.smokeMusicTargetActive }
        for cycle in 0..<2 {
            let now = ProcessInfo.processInfo.systemUptime + Double(cycle) * 2
            panel.smokePointer(inside: true, now: now)
            panel.smokePointer(inside: true, now: now + 0.14)
            try require(panel.isInteracting, "details-owner")
            panel.smokePointer(inside: false, now: now + 0.4)
            panel.smokePointer(inside: false, now: now + 0.64)
            try require(panel.smokeMusicTargetActive, "return-music-owner")
        }
        // Same production gate used when settings/menu/popover disallow music.
        panel.setMusicPresentationAllowed(false)
        try require(!panel.smokeMusicTargetActive, "gate-closes-music")
        panel.setMusicPresentationAllowed(true)
        try require(panel.smokeMusicTargetActive, "gate-restores-music")
        capture.stop()
        try require(!capture.hasScheduledDeadline && !capture.isRecording, "stop-no-deadline")
        let data = try capture.recorder.exportData()
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["PRIVATE_SONG_SENTINEL", "PRIVATE_ARTIST_SENTINEL", "PRIVATE_ALBUM_SENTINEL",
                          "PRIVATE_LYRICS_SENTINEL", "PRIVATE_NEXT_SENTINEL", "synthetic-capture-fixture"] {
            try require(!text.contains(forbidden), "privacy-allowlist")
        }
        let rows = try data.split(separator: 0x0a).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:] }
        let owners = rows.filter { $0["event"] as? String == "ownership" }.compactMap {
            ($0["labels"] as? [String: String])?["owner"]
        }
        try require(owners.filter { $0 == "details" }.count == 2 && owners.filter { $0 == "music" }.count >= 3,
                    "owner-oscillation-observed")
        try require(rows.contains { $0["event"] as? String == "hover" }
                    && rows.contains { $0["event"] as? String == "frame" }, "production-events")
        let before = data
        panel.smokePointer(inside: true, now: ProcessInfo.processInfo.systemUptime + 20)
        try require(try capture.recorder.exportData() == before, "stopped-inert")
        // Expiry may be observed by an input before the run-loop deadline fires.
        var fakeNow = 0.0
        let expiring = DebugCaptureController(recorder: DebugCapture(duration: 1, clock: { fakeNow }))
        expiring.start(); fakeNow = 2; expiring.recorder.count(.polls)
        try require(!expiring.isRecording && !expiring.hasScheduledDeadline && expiring.hasCapture,
                    "input-expiry-updates-controller")
        for line in text.split(separator: "\n") { print("DEBUG_CAPTURE_ROW: " + String(line)) }
        let timed = DebugCaptureController(recorder: DebugCapture(duration: 0.05))
        timed.start()
        try await until("idle-deadline") { !timed.isRecording }
        try require(!timed.hasScheduledDeadline && timed.recorder.stopReason == .durationLimit,
                    "idle-no-input-autostop")
        print("DEBUG_CAPTURE_JSON: " + String(decoding: try JSONSerialization.data(withJSONObject: [
            "schema": 1, "realController": true, "syntheticInput": true, "physicalJitterVerified": false,
            "ownerSequence": owners, "privacyAllowlist": true, "stoppedInert": true,
            "inputExpirySynchronized": true, "idleDeadlineStopped": true,
            "noMusicCapture": true, "restartClearsSession": true, "exportBytes": data.count], options: [.sortedKeys]), as: UTF8.self))
    }
}
private actor DebugCaptureReader: MusicSnapshotProvider {
    private let track: MusicTrackIdentity
    init(track: MusicTrackIdentity) { self.track = track }
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        guard let snapshot = MusicPlaybackSnapshot(track: track, state: .playing, position: 1,
                observedAt: ProcessInfo.processInfo.systemUptime) else { return .unavailable(.invalidResponse) }
        return .snapshot(snapshot)
    }
}
#endif
