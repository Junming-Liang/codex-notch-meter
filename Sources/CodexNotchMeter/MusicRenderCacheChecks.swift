#if os(macOS)
import AppKit
import Combine
import QuartzCore
import NotchCore

/// Independent, bounded cache/controller and own-view proof. Every playback
/// source is injected and in-memory; no Music IPC, user files, network or screen capture.
@MainActor
final class MusicRenderCacheChecks {
    private struct Failure: Error { let label: String }
    private let completion: (Bool) -> Void
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private var controllers: [MusicLyricsController] = []
    private var readers: [MusicCacheReader] = []
    private var finished = false
    private var started = false
    private var began: TimeInterval = 0

    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    func stop() {
        finished = true
        watchdog?.invalidate(); watchdog = nil
        controllers.forEach { $0.stop() }; task?.cancel(); task = nil
    }

    func start() {
        guard !started else { return }; started = true; began = CACurrentMediaTime()
        guard CommandLine.arguments.contains("--music-test"),
              CommandLine.arguments.contains("--music-cache-test") else { finish(false); return }
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(false) }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { [weak self] in
            guard let self else { return }
            do { try await self.run(); self.finish(true) }
            catch {
                print("MUSIC_RENDER_CACHE_FAILED: \((error as? Failure)?.label ?? String(describing: error))")
                self.finish(false)
            }
        }
    }

    private func finish(_ success: Bool) {
        guard !finished else { return }; finished = true
        watchdog?.invalidate(); watchdog = nil
        controllers.forEach { $0.stop() }; task?.cancel(); task = nil
        if !success { print("MUSIC_RENDER_CACHE_FAILED: bounded-verification") }
        completion(success)
    }

    private func require(_ value: Bool, _ label: String) throws {
        if !value { throw Failure(label: label) }
    }

    private func until(_ label: String, timeout: TimeInterval = 4,
                       _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !finished && !Task.isCancelled && CACurrentMediaTime() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(label: label)
    }

    private func layoutChecks() throws -> [[String: Any]] {
        var cache = MusicPreviewLayout.Cache()
        let firstTrack = UUID(), secondTrack = UUID()
        let original = "Silver lanterns follow the tide while amber windows welcome the rain along the quiet harbor"
        var line = original, next = "", track = firstTrack
        var rows: [[String: Any]] = []
        func height(_ width: CGFloat) -> CGFloat {
            cache.contentHeight(trackRevision: track, line: line, nextLine: next, width: width,
                countSyntheticMeasurement: true)
        }
        func record(_ name: String, width: CGFloat, count: UInt64) throws {
            let actual = height(width), expected = MusicPreviewLayout.contentHeight(line: line, nextLine: next, width: width)
            try require(cache.syntheticMeasurementCount == count && actual == expected, "layout-" + name)
            rows.append(["name": name, "measurements": count, "height": Double(actual), "uncachedHeight": Double(expected)])
        }
        try record("first", width: 280, count: 1)
        for _ in 0..<100 { _ = height(280) }
        try record("repeat", width: 280, count: 1)
        try record("two-widths", width: 360, count: 2)
        for _ in 0..<100 { _ = height(280); _ = height(360) }
        try record("alternating", width: 360, count: 2)
        try record("third-width", width: 320, count: 3)
        try record("recent-hit", width: 360, count: 3)
        try record("evicted-width", width: 280, count: 4)
        line = "Quiet kites circle the harbor"
        try record("line", width: 280, count: 5)
        next = "A real following cue"
        try record("next-present", width: 280, count: 6)
        next = "Another real following cue"
        try record("next-content", width: 280, count: 6)
        track = secondTrack
        try record("track", width: 280, count: 7)
        try record("width-normalized", width: 0, count: 8)
        _ = height(-1); _ = height(.nan); _ = height(.infinity)
        try record("normalized-hit", width: 1, count: 8)
        cache.clear()
        try record("clear", width: 1, count: 9)
        try require(MusicPreviewLayout.currentFontSize == 18 && MusicPreviewLayout.nextFontSize == 12,
            "fixed-font-strategy")
        return rows
    }

    private func fixture(document: LyricsDocument) -> (MusicLyricsController, MusicCacheReader) {
        let reader = MusicCacheReader()
        let controller = MusicLyricsController(synthetic: true, reader: reader,
            importer: { _ in document })
        controllers.append(controller); readers.append(reader)
        controller.start(); controller.setEnabled(true)
        return (controller, reader)
    }

    @discardableResult
    private func sample(_ controller: MusicLyricsController, _ reader: MusicCacheReader,
                        track: MusicTrackIdentity, artwork: MusicArtwork?, position: Double = 1,
                        state: MusicPlaybackState = .playing) async throws -> MusicPlaybackSnapshot {
        try await until("await-real-poll") { await reader.hasPending }
        let observed = ProcessInfo.processInfo.systemUptime
        guard let value = MusicPlaybackSnapshot(track: track, state: state, position: position,
            observedAt: observed, artwork: artwork) else { throw Failure(label: "invalid-synthetic-sample") }
        try require(await reader.deliver(.snapshot(value)), "deliver-real-poll")
        try await until("receive-real-poll") { controller.syntheticPlaybackSnapshot?.observedAt == observed }
        return value
    }

    private func eventTimerRecovery(document: LyricsDocument, track: MusicTrackIdentity) async throws -> [String: Any] {
        guard let screen = NSScreen.main else { throw Failure(label: "native-screen") }
        let screenFrame = screen.frame, inset: CGFloat = 32, halfWidth: CGFloat = 110
        guard let notch = NotchGeometry.calculate(screen: screenFrame, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: screenFrame.minX, y: screenFrame.maxY - inset,
                width: screenFrame.midX - halfWidth - screenFrame.minX, height: inset),
            auxiliaryRight: CGRect(x: screenFrame.midX + halfWidth, y: screenFrame.maxY - inset,
                width: screenFrame.maxX - screenFrame.midX - halfWidth, height: inset)) else {
            throw Failure(label: "native-geometry")
        }
        let (controller, reader) = fixture(document: document)
        _ = try await sample(controller, reader, track: track, artwork: nil)
        let model = MeterModel(demo: true, music: controller)
        let geometry = IslandGeometry(notch: notch, screen: screenFrame,
            backingScale: screen.backingScaleFactor, contentHeight: 260)
        let panel = IslandPanelController(model: model, geometry: geometry, startPolling: true,
            reducedMotionOverride: false, hovered: {}, refresh: {}, settings: {}, quit: {})
        let source = TopEdgePanel(contentRect: CGRect(x: -900, y: -700, width: 240, height: 180),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; source.acceptsMouseMovedEvents = true
        source.ignoresMouseEvents = true; source.orderFrontRegardless()
        defer { panel.stop(); source.close(); controller.stop() }
        let corridor = geometry.musicGestureCorridor
        let y = corridor.minY + 2
        let endpoint = CGPoint(x: corridor.maxX - 20, y: y)
        panel.smokeSetPolledPointer(endpoint)
        let path = [CGPoint(x: corridor.minX + 20, y: y), CGPoint(x: corridor.midX, y: y), endpoint]
        try require(path.allSatisfy { geometry.canonicalHoverContains($0, progress: 1) }, "crossing-stays-in-envelope")
        let began = ProcessInfo.processInfo.systemUptime
        var constructed: [[String: Any]] = []
        func point(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
        func post(_ p: CGPoint) async throws -> IslandPointerIngressReceipt {
            let number = 28_000 + constructed.count, requested = ProcessInfo.processInfo.systemUptime
            let location = source.convertPoint(fromScreen: p)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: location,
                modifierFlags: [], timestamp: requested, windowNumber: source.windowNumber,
                context: nil, eventNumber: number, clickCount: 0, pressure: 0) else {
                throw Failure(label: "construct-local-event")
            }
            let timestamp = event.timestamp
            try require(event.window === source && event.eventNumber == number
                && event.locationInWindow == location && timestamp.isFinite
                && abs(timestamp - requested) < 1e-9, "constructed-event-identity")
            // The native queue quantizes timestamps below one nanosecond (also
            // measured by the independent pointer-ingress gate). Resolve the
            // unique delivered event first, then bind acceptance exactly to its
            // delivered timestamp. Construction-time bit equality loses a real
            // accepted event even though all identity bounds are satisfied.
            func localEntry() -> IslandPointerEntryReceipt? {
                let entries = panel.smokePointerEntries.filter { $0.monitor == "local" && $0.eventNumber == number }
                guard entries.count == 1, let entry = entries.first,
                      entry.eventType == NSEvent.EventType.mouseMoved.rawValue,
                      entry.windowNumber == source.windowNumber, entry.localPoint == location, entry.screenPoint == p,
                      entry.timestamp.isFinite, abs(entry.timestamp - requested) < 1e-9,
                      abs(entry.timestamp - timestamp) < 1e-9 else { return nil }
                return entry
            }
            func acceptedReceipt() -> IslandPointerIngressReceipt? {
                guard let entry = localEntry() else { return nil }
                return panel.smokePointerIngress.first {
                    $0.kind == "event" && $0.timestamp == entry.timestamp && $0.point == entry.screenPoint
                }
            }
            NSApp.postEvent(event, atStart: false)
            do {
                try await until("accepted-local-event", timeout: 1) { acceptedReceipt() != nil }
            } catch {
                // Failure-only, bounded diagnostics distinguish missing delivery,
                // native identity drift, and production rejection on the next run.
                let entries = panel.smokePointerEntries.filter { $0.eventNumber == number }.prefix(8)
                let evidence: [String: Any] = ["eventNumber": number, "windowNumber": source.windowNumber,
                    "requestedTimestamp": requested, "constructedTimestamp": timestamp,
                    "expectedPoint": point(p), "expectedLocalPoint": point(location),
                    "monitorEntries": entries.map { e -> [String: Any] in
                        ["monitor": e.monitor, "eventType": e.eventType, "windowNumber": e.windowNumber,
                         "timestamp": e.timestamp, "deltaNanoseconds": (e.timestamp - timestamp) * 1e9,
                         "screenPoint": point(e.screenPoint), "localPoint": point(e.localPoint),
                         "stopped": e.stopped, "placementValid": e.placementValid]
                    },
                    "recentReceipts": panel.smokePointerIngress.suffix(8).map { r -> [String: Any] in
                        ["kind": r.kind, "timestamp": r.timestamp, "point": point(r.point)]
                    }]
                if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    print("MUSIC_RENDER_CACHE_INGRESS_DIAGNOSTIC_JSON: " + json)
                }
                throw error
            }
            guard let entry = localEntry(), let receipt = acceptedReceipt() else {
                throw Failure(label: "unique-local-event-receipt")
            }
            constructed.append(["eventNumber": number, "eventType": entry.eventType, "windowNumber": entry.windowNumber,
                "requestedTimestamp": requested, "constructedTimestamp": timestamp, "deliveredTimestamp": entry.timestamp,
                "deliveredAt": entry.delivered, "screenPoint": point(p), "localPoint": point(location),
                "owner": String(describing: receipt.owner), "target": receipt.target])
            return receipt
        }
        var failed: IslandPointerIngressReceipt?
        for p in path {
            failed = try await post(p)
            if p != endpoint { try await Task.sleep(nanoseconds: 40_000_000) }
        }
        guard let failed, let failedEntry = panel.smokePointerEntries.last(where: { $0.eventNumber == 28_002 }) else {
            throw Failure(label: "failed-open-event")
        }
        try require(controller.isFreshPlaying && !controller.isPlayingForPresentation && !controller.lyricsModeEnabled
            && failed.owner == .idle && failed.target == 0 && !panel.isInteracting,
            "unavailable-lyrics-open-does-not-claim")
        try await until("first-natural-quiet-poll", timeout: 1) {
            panel.smokePointerIngress.contains { $0.kind == "poll" && $0.timestamp > failed.timestamp }
        }
        guard let firstPoll = panel.smokePointerIngress.first(where: { $0.kind == "poll" && $0.timestamp > failed.timestamp }) else {
            throw Failure(label: "missing-first-poll")
        }
        try require(firstPoll.point == endpoint && firstPoll.owner == .idle && firstPoll.target == 0
            && firstPoll.timestamp - failedEntry.delivered > 0.25 && !panel.isInteracting,
            "first-poll-starts-fresh-hover-dwell")
        // Immediately replace the event history after its quiet-period poll,
        // then keep events flowing faster than the 250 ms poll guard. A timeout
        // of the old 1.2 s recognizer cannot make this negative control pass.
        let firstEvent = try await post(endpoint)
        try require(firstEvent.owner == .idle && firstEvent.target == 0, "first-reentry-event-still-idle")
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 40_000_000)
            _ = try await post(endpoint)
        }
        guard let detailsEvent = panel.smokePointerIngress.first(where: {
            $0.kind == "event" && $0.timestamp > firstPoll.timestamp && $0.owner == .details
        }), let lastEvent = panel.smokePointerIngress.last(where: { $0.kind == "event" }) else {
            throw Failure(label: "event-stream-did-not-recover-details")
        }
        let recovery = detailsEvent.timestamp - firstPoll.timestamp
        try require(recovery >= 0.12 && recovery < 0.8 && detailsEvent.point == endpoint
            && !panel.smokePointerIngress.contains(where: {
                $0.kind == "poll" && $0.timestamp > firstPoll.timestamp && $0.timestamp < detailsEvent.timestamp
            }), "events-recover-before-recognizer-timeout")
        try await until("quiet-poll-retains-details", timeout: 1) {
            panel.smokePointerIngress.contains { $0.kind == "poll" && $0.timestamp > lastEvent.timestamp && $0.owner == .details }
        }
        guard let finalPoll = panel.smokePointerIngress.first(where: { $0.kind == "poll" && $0.timestamp > lastEvent.timestamp }) else {
            throw Failure(label: "missing-final-poll")
        }
        let lastDelivered = panel.smokePointerEntries.last(where: { $0.eventNumber == 28_008 })?.delivered ?? .infinity
        try require(finalPoll.owner == .details && finalPoll.point == endpoint
            && finalPoll.timestamp - lastDelivered > 0.25, "final-poll-keeps-details")
        try await until("recovered-natural-details-paint", timeout: 2) {
            guard let paint = panel.paintReceipt else { return false }
            let expected = panel.geometry.frame(progress: 1), probe = panel.motionProbe
            return !probe.running && probe.requestedProgress == 1 && probe.renderedProgress == 1
                && probe.frame == expected && probe.viewport == expected.size && probe.visible && probe.nonKey
                && paint.observed >= detailsEvent.timestamp && paint.frame.progress == 1
                && paint.actualViewport == expected.size && paint.nativeFrame == expected
        }
        let receipts = panel.smokePointerIngress.filter { $0.timestamp >= began }
        try require(!panel.smokePointerEntriesOverflow && !panel.smokeHistoryOverflow
            && receipts.allSatisfy { geometry.canonicalHoverContains($0.point, progress: 1) }
            && controller.isFreshPlaying && !controller.isPlayingForPresentation && !controller.lyricsModeEnabled,
            "recovery-no-exit-or-new-lyrics")
        func receipt(_ r: IslandPointerIngressReceipt) -> [String: Any] {
            ["kind": r.kind, "owner": String(describing: r.owner), "target": r.target,
             "point": point(r.point), "timestamp": r.timestamp]
        }
        return ["syntheticPollLocation": true, "nativeLocalEvents": true, "globalSystemDelivery": false,
            "actualTimerPolling": true, "naturalPaint": true, "noEnvelopeExit": true,
            "unavailableLyrics": true, "eventRecoverySeconds": recovery,
            "firstPollQuietSeconds": firstPoll.timestamp - failedEntry.delivered,
            "constructed": constructed,
            "sequence": [receipt(failed), receipt(firstPoll), receipt(firstEvent), receipt(detailsEvent), receipt(finalPoll)]]
    }

    private func run() async throws {
        let layout = try layoutChecks()
        let document = try LRCParser.parse("[00:00]Amber paper birds cross the bay\n[00:45]Quiet kites circle the harbor")
        guard let track = MusicTrackIdentity(title: "Synthetic Cache A", artist: "Fixture", album: "Cache", duration: 120),
              let otherTrack = MusicTrackIdentity(title: "Synthetic Cache B", artist: "Fixture", album: "Cache", duration: 120),
              let artA = MusicArtwork(rgbaBytes: Data([255, 0, 0, 255]), pixelWidth: 1, pixelHeight: 1),
              let artB = MusicArtwork(rgbaBytes: Data([0, 255, 0, 255]), pixelWidth: 1, pixelHeight: 1) else {
            throw Failure(label: "synthetic-values")
        }
        let (controller, reader) = fixture(document: document)
        let initial = try await sample(controller, reader, track: track, artwork: artA)
        guard let token = controller.importSelectionToken else { throw Failure(label: "import-token") }
        controller.importLyrics(from: URL(fileURLWithPath: "/synthetic-cache-in-memory.lrc"), for: token)
        try await until("in-memory-import") { controller.hasLocalLyrics && controller.isPlayingForPresentation }
        controller.selectLyricsMode(true)
        guard let firstImage = controller.artworkImage else { throw Failure(label: "first-image") }
        try require(controller.syntheticArtworkImageBuildCount == 1, "first-image-build")
        for _ in 0..<100 {
            _ = controller.previewContentHeight(width: 280)
            _ = controller.previewContentHeight(width: 360)
        }
        try require(controller.syntheticPreviewHeightMeasurementCount == 2, "controller-two-width-cache")
        let revision = controller.presentationRevision
        var publications = 0
        let observer = controller.objectWillChange.sink { publications += 1 }
        var latest = initial
        for position in [2.0, 3.0, 4.0] {
            latest = try await sample(controller, reader, track: track, artwork: artA, position: position)
        }
        observer.cancel()
        let reusedImage = controller.artworkImage === firstImage
        let revisionUnchanged = controller.presentationRevision == revision
        let identicalImageBuilds = controller.syntheticArtworkImageBuildCount ?? 0
        try require(publications == 0 && revisionUnchanged && reusedImage
            && controller.syntheticArtworkImageBuildCount == 1
            && latest.observedAt > initial.observedAt + 2 && latest.position == 4
            && controller.isFreshPlaying && controller.isPlayingForPresentation && controller.lyricsModeEnabled,
            "identical-polls-without-publications")
        // Leave the next actual reader suspended. Its presence cannot refresh the
        // most recent delivered source's five-second freshness deadline.
        try await until("held-read") { await reader.hasPending }
        try await until("freshness-expires", timeout: 6) { !controller.isFreshPlaying }
        let freshnessAge = ProcessInfo.processInfo.systemUptime - latest.observedAt
        try require(freshnessAge >= 5 && freshnessAge < 6.5 && controller.line.isEmpty
            && controller.nextLine.isEmpty && controller.trackTitle.isEmpty
            && controller.artwork == nil && controller.artworkImage == nil
            && !controller.isPlayingForPresentation && controller.lyricsModeEnabled,
            "freshness-clears-presentation-and-image")
        _ = try await sample(controller, reader, track: track, artwork: artA, position: 10)
        try require(controller.isPlayingForPresentation && controller.hasLocalLyrics
            && controller.syntheticArtworkImageBuildCount == 2, "fresh-resume")
        let resumedImage = controller.artworkImage
        _ = try await sample(controller, reader, track: track, artwork: artB, position: 11)
        try require(controller.artwork == artB && controller.artworkImage != nil
            && controller.artworkImage !== resumedImage && controller.syntheticArtworkImageBuildCount == 3,
            "artwork-replacement")
        let replacementBuilds = controller.syntheticArtworkImageBuildCount ?? 0
        _ = try await sample(controller, reader, track: track, artwork: nil, position: 12, state: .paused)
        try require(controller.artwork == nil && controller.artworkImage == nil && controller.line.isEmpty
            && controller.nextLine.isEmpty && !controller.isFreshPlaying && !controller.isPlayingForPresentation
            && controller.lyricsModeEnabled && controller.hasLocalLyrics, "pause-clears-image")
        _ = try await sample(controller, reader, track: track, artwork: artB, position: 13)
        try require(controller.isPlayingForPresentation && controller.syntheticArtworkImageBuildCount == 4,
            "pause-resume")
        let resumeBuilds = controller.syntheticArtworkImageBuildCount ?? 0
        _ = try await sample(controller, reader, track: otherTrack, artwork: nil)
        try require(controller.artwork == nil && controller.artworkImage == nil && controller.line.isEmpty
            && controller.nextLine.isEmpty && !controller.hasLocalLyrics && !controller.isPlayingForPresentation,
            "new-track-without-art")
        controller.stop()

        var boundaries: [String] = ["freshness", "pause", "new-track"]
        for boundary in ["disable", "sleep", "stop", "soft-failure"] {
            let (c, r) = fixture(document: document)
            _ = try await sample(c, r, track: track, artwork: artA)
            try require(c.artworkImage != nil, "boundary-start-" + boundary)
            switch boundary {
            case "disable": c.setEnabled(false)
            case "sleep": c.setActive(false)
            case "stop": c.stop()
            default:
                try await until("boundary-pending-read") { await r.hasPending }
                try require(await r.deliver(.unavailable(.timedOut)), "boundary-deliver-failure")
                try await until("boundary-failure-received") { !c.isFreshPlaying }
            }
            try require(c.artwork == nil && c.artworkImage == nil && !c.isFreshPlaying,
                "boundary-clears-" + boundary)
            boundaries.append(boundary); c.stop()
        }
        let eventRecovery = try await eventTimerRecovery(document: document, track: track)
        let indicator = try await MusicPlayingIndicatorVerification.run(outputDirectory:
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("dist/contour-rendering/indicator", isDirectory: true))
        try await until("all-reads-retired") {
            for r in self.readers { if await r.hasPending { return false } }
            return true
        }
        var pending = 0, calls = 0
        for r in readers { pending += await r.pendingCount; calls += await r.callCount }
        let result: [String: Any] = [
            "schema": 1, "synthetic": true, "realPolling": true, "controllerOnly": false, "scanout": false,
            "deadlineSeconds": 30, "elapsed": CACurrentMediaTime() - began,
            "layout": layout, "fontStrategyEquivalent": true, "controllerWidthMeasurements": 2,
            "identicalPolls": 3, "publications": publications, "presentationRevisionUnchanged": revisionUnchanged,
            "identicalImageReused": reusedImage, "identicalImageBuilds": identicalImageBuilds,
            "freshnessAge": freshnessAge, "latestPosition": latest.position,
            "sourceObservationAdvanced": latest.observedAt > initial.observedAt + 2,
            "replacementBuilds": replacementBuilds, "resumeBuilds": resumeBuilds, "clearBoundaries": boundaries,
            "eventRecovery": eventRecovery,
            "indicator": indicator,
            "controllers": controllers.count, "readerCalls": calls, "pendingRequests": pending
        ]
        guard let text = String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8) else {
            throw Failure(label: "json-encoding")
        }
        print("MUSIC_RENDER_CACHE_JSON: " + text)
        print("MUSIC_RENDER_CACHE_OK: independent=true deadline=30 realPolling=true boundedCache=true synthetic=true scanout=false")
    }
}

private actor MusicCacheReader: MusicSnapshotProvider {
    private var nextID = 0
    private var pending: (Int, CheckedContinuation<MusicReadResult, Never>)?
    private(set) var callCount = 0
    var hasPending: Bool { pending != nil }
    var pendingCount: Int { pending == nil ? 0 : 1 }

    func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        guard pending == nil, !Task.isCancelled else { return .unavailable(.cancelled) }
        nextID += 1; let id = nextID; callCount += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .unavailable(.cancelled)) }
                else { pending = (id, continuation) }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }
    func deliver(_ value: MusicReadResult) -> Bool {
        guard let saved = pending else { return false }
        pending = nil; saved.1.resume(returning: value); return true
    }
    private func cancel(id: Int) {
        guard pending?.0 == id else { return }
        _ = deliver(.unavailable(.cancelled))
    }
}
#endif
