#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Own-window event delivery plus the unmodified 30 Hz production timer. The
/// explicit fixture flags isolate only the sampled poll location; timestamps,
/// event dispatch, quiet guarding, hover decisions and painting remain native.
/// This file deliberately uses only probes present in v111, so the exact same
/// fixture can demonstrate old-code failure without transplanting a new helper.
@MainActor
final class MusicStationaryHoverChecks {
    private struct Failure: Error { let label: String }
    private let completion: (Bool) -> Void
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private var finished = false
    private var started = false
    private var active: Fixture?
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    func stop() {
        finished = true; watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil; active?.stop(); active = nil
    }
    func start() {
        guard !started else { return }; started = true
        guard ["--music-test", "--music-cache-test", "--music-stationary-hover-test"].allSatisfy({ CommandLine.arguments.contains($0) }),
              !CommandLine.arguments.contains("--gesture-recovery-test") else { finish(false); return }
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(false) }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let began = ProcessInfo.processInfo.systemUptime
                var rows: [[String: Any]] = []
                for edge in ["left", "right"] { rows.append(try await self.edge(edge)) }
                rows.append(try await self.controls())
                self.emit("MUSIC_STATIONARY_HOVER_JSON", ["schema": 1, "syntheticPollLocation": true,
                    "nativeLocalEvents": true, "actualTimerPolling": true, "globalSystemDelivery": false,
                    "naturalPaint": true, "deadlineSeconds": 60,
                    "elapsed": ProcessInfo.processInfo.systemUptime - began, "cases": rows])
                print("MUSIC_STATIONARY_HOVER_OK: nativeLocal=true naturalPoll=true synthetic=true")
                self.finish(true)
            } catch {
                print("MUSIC_STATIONARY_HOVER_FAILED: \((error as? Failure)?.label ?? String(describing: error))")
                self.finish(false)
            }
        }
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }; stop(); completion(success)
    }
    private func require(_ condition: Bool, _ label: String) throws {
        if !condition { throw Failure(label: label) }
    }
    private func until(_ label: String, timeout: TimeInterval = 4,
                       _ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !finished && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure(label: label)
    }
    private func emit(_ prefix: String, _ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           data.count <= 131_072, let text = String(data: data, encoding: .utf8) { print(prefix + ": " + text) }
    }
    private func point(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }

    @MainActor private final class Fixture {
        let reader: StationaryHoverReader
        let controller: MusicLyricsController
        let panel: IslandPanelController
        let source: TopEdgePanel
        let outside: CGPoint
        var serial = 31_000
        init(screen: NSScreen, notch: NotchGeometry, track: MusicTrackIdentity, document: LyricsDocument) {
            reader = StationaryHoverReader(track: track)
            controller = MusicLyricsController(synthetic: true, reader: reader, importer: { _ in document })
            let model = MeterModel(demo: true, music: controller)
            let geometry = IslandGeometry(notch: notch, screen: screen.frame,
                backingScale: screen.backingScaleFactor, contentHeight: 260)
            outside = CGPoint(x: geometry.frame(progress: 1).maxX + 80, y: geometry.musicGestureCorridor.minY + 2)
            panel = IslandPanelController(model: model, geometry: geometry, startPolling: true,
                reducedMotionOverride: false, hovered: {}, refresh: {}, settings: {}, quit: {})
            source = TopEdgePanel(contentRect: CGRect(x: -900, y: -700, width: 240, height: 180),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false; source.acceptsMouseMovedEvents = true
            source.ignoresMouseEvents = true; source.orderFrontRegardless()
            panel.smokeSetPolledPointer(outside)
            controller.start(); controller.setEnabled(true)
        }
        func stop() { panel.stop(); source.close(); controller.stop() }
    }
    private func prepare() async throws -> Fixture {
        guard let screen = NSScreen.main else { throw Failure(label: "native-screen") }
        let s = screen.frame, inset: CGFloat = 32, half: CGFloat = 110
        guard let notch = NotchGeometry.calculate(screen: s, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: s.minX, y: s.maxY - inset, width: s.midX - half - s.minX, height: inset),
            auxiliaryRight: CGRect(x: s.midX + half, y: s.maxY - inset, width: s.maxX - s.midX - half, height: inset)),
              let track = MusicTrackIdentity(title: "Stationary Hover A", artist: "Fixture", album: "Native", duration: 120) else {
            throw Failure(label: "fixture-values")
        }
        let document = try LRCParser.parse("[00:00]Synthetic amber birds\n[00:45]Synthetic quiet harbor")
        let f = Fixture(screen: screen, notch: notch, track: track, document: document)
        active = f
        let began = ProcessInfo.processInfo.systemUptime
        try await until("native-source-readiness") {
            let expected = f.panel.geometry.frame(progress: 0), probe = f.panel.motionProbe
            guard f.controller.isFreshPlaying, !probe.running, probe.renderedProgress == 0,
                  probe.frame == expected, probe.viewport == expected.size, probe.visible, probe.nonKey,
                  f.panel.smokeAccessoryProgress == 1, let paint = f.panel.paintReceipt,
                  paint.observed >= began, paint.frame.progress == 0, paint.actualViewport == expected.size,
                  paint.nativeFrame == expected, f.source.isVisible, f.source.windowNumber > 0 else { return false }
            // Inspect only this fixture's own known window, never other windows.
            let number = CGWindowID(f.source.windowNumber)
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]]
            guard let own = info?.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
            }), let bounds = own[kCGWindowBounds as String] as? [String: Any],
                  let server = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            let top = NSScreen.screens.first?.frame.maxY ?? s.maxY
            let expectedServer = CGRect(x: f.source.frame.minX, y: top - f.source.frame.maxY,
                width: f.source.frame.width, height: f.source.frame.height)
            let p = CGPoint(x: f.panel.geometry.musicGestureCorridor.minX + 20,
                y: f.panel.geometry.musicGestureCorridor.minY + 2)
            let local = f.source.convertPoint(fromScreen: p)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: local, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.source.windowNumber,
                context: nil, eventNumber: 30_999, clickCount: 0, pressure: 0) else { return false }
            return server == expectedServer && event.window === f.source
                && event.cgEvent?.location == CGPoint(x: p.x, y: top - p.y)
        }
        let initial = f.panel.smokeMusicInputState(at: f.outside)
        try require(initial?["needsCorridorExit"] as? Bool == false
            && initial?["gestureSuppressed"] as? Bool == false && !f.controller.hasLocalLyrics
            && !f.controller.lyricsModeEnabled && f.panel.smokeExpansionOwner == .idle,
            "fresh-fixture-no-prior-crossing")
        return f
    }
    private struct Queued {
        let number: Int
        let requested: TimeInterval
        let local: CGPoint
        let screen: CGPoint
    }
    private func enqueue(_ p: CGPoint, _ f: Fixture) throws -> Queued {
        f.serial += 1; let number = f.serial
        let requested = ProcessInfo.processInfo.systemUptime, local = f.source.convertPoint(fromScreen: p)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: local, modifierFlags: [],
            timestamp: requested, windowNumber: f.source.windowNumber, context: nil,
            eventNumber: number, clickCount: 0, pressure: 0) else { throw Failure(label: "construct-event") }
        try require(event.window === f.source && event.locationInWindow == local
            && abs(event.timestamp - requested) < 1e-9, "constructed-event-identity")
        NSApp.postEvent(event, atStart: false)
        return Queued(number: number, requested: requested, local: local, screen: p)
    }
    private func delivered(_ queued: Queued, _ f: Fixture) async throws -> IslandPointerEntryReceipt {
        let number = queued.number, requested = queued.requested, local = queued.local, p = queued.screen
        try await until("native-local-receipt", timeout: max(0.001, requested + 1 - ProcessInfo.processInfo.systemUptime)) {
            f.panel.smokePointerEntries.contains { $0.monitor == "local" && $0.eventNumber == number }
        }
        let entries = f.panel.smokePointerEntries.filter { $0.monitor == "local" && $0.eventNumber == number }
        guard entries.count == 1, let e = entries.first else { throw Failure(label: "unique-native-receipt") }
        try require(e.windowNumber == f.source.windowNumber && e.eventType == NSEvent.EventType.mouseMoved.rawValue
            && e.localPoint == local && e.screenPoint == p && abs(e.timestamp - requested) < 1e-9
            && e.delivered >= requested && e.delivered - requested < 1 && e.buttons.isEmpty
            && !e.stopped && e.placementValid
            && f.panel.smokePointerIngress.contains { $0.kind == "event" && $0.timestamp == e.timestamp && $0.point == p },
            "native-coordinate-time-and-production-acceptance")
        return e
    }
    @discardableResult private func post(_ p: CGPoint, _ f: Fixture) async throws -> IslandPointerEntryReceipt {
        let queued = try enqueue(p, f)
        return try await delivered(queued, f)
    }
    private func edge(_ name: String) async throws -> [String: Any] {
        let f = try await prepare(); defer { f.stop(); active = nil }
        let corridor = f.panel.geometry.musicGestureCorridor
        let center = CGPoint(x: name == "left" ? corridor.minX + 20 : corridor.maxX - 20, y: corridor.minY + 2)
        let began = ProcessInfo.processInfo.systemUptime
        var entries: [IslandPointerEntryReceipt] = []
        var rows: [[String: Any]] = []
        var completed = false
        var playbackReads = 0
        defer {
            if !completed { emit("MUSIC_STATIONARY_HOVER_DIAGNOSTIC_JSON", ["name": name, "events": rows,
                "center": point(center), "corridor": [Double(corridor.minX), Double(corridor.minY), Double(corridor.width), Double(corridor.height)],
                "sourceWindowNumber": f.source.windowNumber, "playbackReads": playbackReads,
                "freshPlaying": f.controller.isFreshPlaying, "noLyricsSelected": !f.controller.lyricsModeEnabled,
                "unavailableLyrics": !f.controller.hasLocalLyrics, "nativeSourceReady": true,
                "receipts": f.panel.smokePointerIngress.filter { $0.timestamp >= began }.map { r -> [String: Any] in
                    var row: [String: Any] = ["kind": r.kind, "timestamp": r.timestamp, "point": point(r.point),
                        "owner": String(describing: r.owner), "target": r.target]
                    if let h = r.hoverDecision { row["hover"] = ["timestamp": h.timestamp, "inside": h.inside,
                        "expandedBefore": h.expandedBefore, "expandedAfter": h.expandedAfter] }
                    return row
                }, "inputState": f.panel.smokeMusicInputState(at: center) ?? [:]]) }
        }
        for index in 0..<16 {
            // Schedule from the previous actual delivery. A task wake never
            // substitutes for receipt time or proves that a poll actually ran.
            if let previous = entries.last {
                // A runnable Task can resume before the run loop services a
                // delayed Timer. Queueing at +0.30 alone can reset the quiet
                // guard before any real poll is accepted. Wait for its receipt,
                // without extending the existing 0.45 s delivery bound.
                try await until("actual-poll-before-next-event-" + name,
                    timeout: max(0.001, previous.delivered + 0.45 - ProcessInfo.processInfo.systemUptime)) {
                    ProcessInfo.processInfo.systemUptime >= previous.delivered + 0.30
                        && f.panel.smokePointerIngress.contains {
                            $0.kind == "poll" && $0.timestamp > previous.delivered
                        }
                }
            }
            let p = CGPoint(x: center.x + (index % 2 == 0 ? -1 : 1), y: center.y)
            f.panel.smokeSetPolledPointer(p)
            let e = try await post(p, f)
            if let previous = entries.last {
                let gap = e.delivered - previous.delivered
                let polls = f.panel.smokePointerIngress.filter {
                    $0.kind == "poll" && $0.timestamp > previous.delivered && $0.timestamp < e.delivered
                }
                try require(gap >= 0.30 && gap <= 0.45 && !polls.isEmpty,
                    "actual-event-poll-alternation-" + name)
                try require(polls.allSatisfy { $0.timestamp - previous.delivered > 0.25
                    && abs($0.point.x - center.x) <= 1 && $0.point.y == center.y }, "natural-quiet-guard-" + name)
                rows.append(["eventNumber": e.eventNumber, "sourceAt": e.timestamp, "deliveredAt": e.delivered,
                    "point": point(e.screenPoint), "localPoint": point(e.localPoint), "gap": gap,
                    "polls": polls.map { ["timestamp": $0.timestamp, "point": point($0.point),
                        "owner": String(describing: $0.owner), "target": $0.target] as [String: Any] }])
            } else {
                rows.append(["eventNumber": e.eventNumber, "sourceAt": e.timestamp, "deliveredAt": e.delivered,
                    "point": point(e.screenPoint), "localPoint": point(e.localPoint)])
            }
            entries.append(e)
            playbackReads = await f.reader.callCount
            try require(f.controller.isFreshPlaying && !f.controller.hasLocalLyrics && !f.controller.lyricsModeEnabled,
                "fresh-unavailable-lyrics-" + name)
        }
        let receipts = f.panel.smokePointerIngress.filter { $0.timestamp >= began }
        let decisions = receipts.compactMap { $0.hoverDecision }.filter { $0.expandedAfter }
        // This exact label is the expected v111 red: cross-source recognizer
        // resets perpetually re-arm reservation despite remaining at one edge.
        guard let recovery = decisions.first else { throw Failure(label: "ordinary-edge-hover-starved-" + name) }
        try require(recovery.timestamp - entries[0].delivered >= 0.12
            && recovery.timestamp - entries[0].delivered < 2.0
            && entries.last!.delivered - entries[0].delivered >= 4.5
            && f.panel.smokeExpansionOwner == .details && f.panel.smokeTargetProgress == 1,
            "bounded-recovery-sustained-across-reservation-windows-" + name)
        try require(receipts.allSatisfy { abs($0.point.x - center.x) <= 1 && $0.point.y == center.y
            && f.panel.geometry.canonicalHoverContains($0.point, progress: 1) }
            && !f.panel.smokePointerEntriesOverflow && !f.panel.smokeHistoryOverflow,
            "no-crossing-or-envelope-exit-" + name)
        try await until("natural-expanded-paint-" + name) {
            guard let paint = f.panel.paintReceipt else { return false }
            let expected = f.panel.geometry.frame(progress: 1), probe = f.panel.motionProbe
            return !probe.running && probe.renderedProgress == 1 && probe.requestedProgress == 1
                && paint.observed >= recovery.timestamp && paint.frame.progress == 1
                && paint.actualViewport == expected.size && paint.nativeFrame == expected && probe.nonKey
        }
        guard let paint = f.panel.paintReceipt else { throw Failure(label: "missing-final-paint") }
        let expected = f.panel.geometry.frame(progress: 1)
        func rectangle(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        let painting: [String: Any] = ["observedAt": paint.observed, "progress": paint.frame.progress,
            "nativeFrame": rectangle(paint.nativeFrame), "expectedFrame": rectangle(expected),
            "viewport": [Double(paint.actualViewport.width), Double(paint.actualViewport.height)]]
        let calls = await f.reader.callCount
        try require(calls >= 4, "real-playback-refresh-over-long-dwell")
        f.panel.smokeSetPolledPointer(f.outside); _ = try await post(f.outside, f)
        try await until("ordinary-hover-leave-" + name) { f.panel.smokeExpansionOwner == .idle && f.panel.smokeProgress == 0 }
        completed = true
        return ["name": name, "events": rows, "recoverySeconds": recovery.timestamp - entries[0].delivered,
            "duration": entries.last!.delivered - entries[0].delivered, "playbackReads": calls,
            "naturalPaint": true, "noLyricsSelected": true, "leaveCollapsed": true,
            "paint": painting, "recoveryAt": recovery.timestamp, "center": point(center),
            "corridor": rectangle(corridor), "sourceWindowNumber": f.source.windowNumber,
            "receipts": receipts.map { r -> [String: Any] in
                var row: [String: Any] = ["kind": r.kind, "timestamp": r.timestamp, "point": point(r.point),
                    "owner": String(describing: r.owner), "target": r.target]
                if let h = r.hoverDecision { row["hover"] = ["timestamp": h.timestamp, "inside": h.inside,
                    "expandedBefore": h.expandedBefore, "expandedAfter": h.expandedAfter] }
                return row
            }]
    }
    private func controls() async throws -> [String: Any] {
        let f = try await prepare(); defer { f.stop(); active = nil }
        var completed = false
        var phase = "import"
        defer {
            if !completed {
                let probe = f.panel.motionProbe
                var diagnostic: [String: Any] = ["name": "controls", "phase": phase,
                    "freshPlaying": f.controller.isFreshPlaying,
                    "playingForPresentation": f.controller.isPlayingForPresentation,
                    "lyricsSelected": f.controller.lyricsModeEnabled,
                    "hasLocalLyrics": f.controller.hasLocalLyrics,
                    "owner": String(describing: f.panel.smokeExpansionOwner),
                    "target": f.panel.smokeTargetProgress,
                    "renderedProgress": probe.renderedProgress, "motionRunning": probe.running,
                    "outsideInputState": f.panel.smokeMusicInputState(at: f.outside) ?? [:],
                    "receipts": f.panel.smokePointerIngress.suffix(24).map { r -> [String: Any] in
                        var row: [String: Any] = ["kind": r.kind, "timestamp": r.timestamp,
                            "point": point(r.point), "owner": String(describing: r.owner), "target": r.target]
                        if let h = r.hoverDecision { row["hover"] = ["timestamp": h.timestamp,
                            "inside": h.inside, "expandedBefore": h.expandedBefore, "expandedAfter": h.expandedAfter] }
                        return row
                    }]
                if let paint = f.panel.paintReceipt {
                    diagnostic["paint"] = ["observedAt": paint.observed, "progress": paint.frame.progress]
                }
                emit("MUSIC_STATIONARY_HOVER_DIAGNOSTIC_JSON", diagnostic)
            }
        }
        guard let token = f.controller.importSelectionToken else { throw Failure(label: "controls-import-token") }
        f.controller.importLyrics(from: URL(fileURLWithPath: "/synthetic-stationary-hover.lrc"), for: token)
        try await until("controls-lyrics-ready") { f.controller.isPlayingForPresentation && f.controller.hasLocalLyrics }
        let c = f.panel.geometry.musicGestureCorridor, y = c.minY + 2
        func crossing(_ right: Bool) async throws {
            let envelope = f.panel.geometry.frame(progress: 1)
            let outside = CGPoint(x: right ? envelope.minX - 80 : envelope.maxX + 80, y: y)
            f.panel.smokeSetPolledPointer(outside); _ = try await post(outside, f)
            let path = [CGPoint(x: right ? c.minX + 20 : c.maxX - 20, y: y),
                CGPoint(x: c.midX, y: y), CGPoint(x: right ? c.maxX - 20 : c.minX + 20, y: y)]
            // Queue the complete trajectory synchronously. Waiting between
            // individual AppKit dispatches can manufacture a >250 ms gap.
            let queued = try path.map { try enqueue($0, f) }
            var entries: [IslandPointerEntryReceipt] = []
            for event in queued { entries.append(try await delivered(event, f)) }
            try require(zip(entries, entries.dropFirst()).allSatisfy { a, b in b.timestamp > a.timestamp
                && b.timestamp - a.timestamp < 0.25 && b.delivered >= a.delivered
                && b.delivered - a.delivered < 0.25 }, "controls-continuous-native-crossing")
            f.panel.smokeSetPolledPointer(path.last!)
        }
        phase = "crossings"
        try await crossing(true)
        try await until("genuine-right-opens-lyrics") { f.controller.lyricsModeEnabled && f.panel.smokeExpansionOwner == .music }
        try await crossing(false)
        try await until("genuine-reverse-closes-lyrics") { !f.controller.lyricsModeEnabled && f.panel.smokeExpansionOwner == .idle }
        try await crossing(true)
        try require(f.controller.lyricsModeEnabled, "genuine-right-reopens-lyrics")
        let endpoint = CGPoint(x: c.maxX - 20, y: y)
        func recordControlState(_ name: String) {
            emit("MUSIC_CONTROL_STATE_JSON", ["phase": name,
                "freshPlaying": f.controller.isFreshPlaying,
                "playingForPresentation": f.controller.isPlayingForPresentation,
                "lyricsSelected": f.controller.lyricsModeEnabled,
                "owner": String(describing: f.panel.smokeExpansionOwner),
                "target": f.panel.smokeTargetProgress,
                "motionRunning": f.panel.motionProbe.running,
                "endpointInputState": f.panel.smokeMusicInputState(at: endpoint) ?? [:]])
        }
        // Preserve the original stationary endpoint scenario. Pause releases
        // the lyric gesture gate, allowing ordinary details hover; resuming
        // playback must not steal that manual owner (IslandExpansionOwner).
        phase = "pause-at-edge"
        recordControlState("before-pause-at-edge")
        await f.reader.setPaused(true)
        try await until("pause-at-edge-clears-lyrics-presentation") {
            !f.controller.isFreshPlaying && !f.controller.isPlayingForPresentation
        }
        try require(f.controller.lyricsModeEnabled && f.controller.hasLocalLyrics,
            "pause-at-edge-preserves-selection-and-document")
        try await until("pause-at-edge-restores-ordinary-details") {
            guard let paint = f.panel.paintReceipt else { return false }
            return f.panel.smokeExpansionOwner == .details && f.panel.smokeTargetProgress == 1
                && paint.frame.progress == 1 && !f.panel.motionProbe.running
        }
        recordControlState("paused-at-edge")
        phase = "resume-under-details"
        await f.reader.setPaused(false)
        try await until("resume-under-details-restores-lyrics") {
            f.controller.isFreshPlaying && f.controller.isPlayingForPresentation
        }
        try require(f.controller.lyricsModeEnabled, "resume-under-details-preserves-selection")
        try await until("resume-preserves-manual-details-owner") {
            guard let paint = f.panel.paintReceipt else { return false }
            return f.panel.smokeExpansionOwner == .details && f.panel.smokeTargetProgress == 1
                && paint.frame.progress == 1 && !f.panel.motionProbe.running
        }
        recordControlState("resumed-under-details")
        // Independently test passive restoration with an explicit native exit.
        // Details must yield to selected Music before the outside pause cycle.
        phase = "exit-before-passive-pause"
        f.panel.smokeSetPolledPointer(f.outside); _ = try await post(f.outside, f)
        try await until("passive-music-owner-before-pause") {
            f.panel.smokeExpansionOwner == .music
                && f.panel.smokeMusicInputState(at: f.outside)?["hoverExpanded"] as? Bool == false
        }
        recordControlState("outside-before-passive-pause")
        phase = "pause"
        await f.reader.setPaused(true)
        try await until("pause-clears-presentation") { !f.controller.isFreshPlaying && !f.controller.isPlayingForPresentation }
        try require(f.controller.lyricsModeEnabled && f.controller.hasLocalLyrics, "pause-preserves-selection-and-document")
        try await until("pause-clears-native-music-owner") {
            guard let paint = f.panel.paintReceipt else { return false }
            return f.panel.smokeExpansionOwner == .idle && f.panel.smokeTargetProgress == 0
                && paint.frame.progress == 0 && !f.panel.motionProbe.running
        }
        recordControlState("paused-outside")
        phase = "resume"
        await f.reader.setPaused(false)
        try await until("resume-restores-lyrics") { f.controller.isFreshPlaying && f.controller.isPlayingForPresentation }
        try require(f.controller.lyricsModeEnabled, "resume-preserves-selection")
        try await until("resume-restores-native-music-owner") {
            guard let paint = f.panel.paintReceipt else { return false }
            return f.panel.smokeExpansionOwner == .music
                && paint.frame.progress == f.panel.smokeTargetProgress
                && !f.panel.motionProbe.running
        }
        recordControlState("resumed-outside")
        phase = "track-change"
        guard let next = MusicTrackIdentity(title: "Stationary Hover B", artist: "Fixture", album: "Native", duration: 120) else {
            throw Failure(label: "controls-next-track")
        }
        await f.reader.setTrack(next)
        try await until("track-change-clears-stale-lyrics") { f.controller.isFreshPlaying && !f.controller.hasLocalLyrics }
        try require(!f.controller.isPlayingForPresentation, "new-track-does-not-reuse-lyrics")
        f.panel.smokeSetPolledPointer(f.outside); _ = try await post(f.outside, f)
        try await until("controls-exit-after-state-change") { f.panel.smokeExpansionOwner == .idle && f.panel.smokeProgress == 0 }
        let center = CGPoint(x: c.midX, y: y)
        f.panel.smokeSetPolledPointer(center); _ = try await post(center, f)
        try await until("controls-ordinary-hover-recovers") {
            guard let paint = f.panel.paintReceipt else { return false }
            return f.panel.smokeExpansionOwner == .details && f.panel.smokeProgress == 1
                && paint.frame.progress == 1 && !f.controller.isPlayingForPresentation
        }
        completed = true
        return ["name": "controls", "genuineRight": true, "genuineReverse": true,
            "pauseResume": true, "trackChange": true, "ordinaryRecovery": true, "nativeEvents": true]
    }
}

private actor StationaryHoverReader: MusicSnapshotProvider {
    private var track: MusicTrackIdentity
    private var paused = false
    private(set) var callCount = 0
    init(track: MusicTrackIdentity) { self.track = track }
    func setPaused(_ value: Bool) { paused = value }
    func setTrack(_ value: MusicTrackIdentity) { track = value }
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        callCount += 1
        guard let snapshot = MusicPlaybackSnapshot(track: track, state: paused ? .paused : .playing,
            position: 1, observedAt: ProcessInfo.processInfo.systemUptime, artwork: nil) else {
            return .unavailable(.cancelled)
        }
        return .snapshot(snapshot)
    }
}
#endif
