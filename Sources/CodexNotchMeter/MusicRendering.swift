#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import Vision
import NotchCore

/// Synthetic, in-process integration of the production controller and existing
/// CompactDetailView. No Music IPC, network, selected files or preference writes.
/// The only raster inspected is this harness's own NSView cache, never a screen.
@MainActor
final class MusicRenderHarness: NSObject {
    private struct Failure: Error { let label: String }
    private static let firstLine = "Silver lanterns follow the tide"
    private static let secondLine = "Quiet kites circle the harbor"
    private static let localLine = "Amber windows welcome the rain"
    private static let obsoleteLine = "Old paper boats wait by the gate"
    private let screen: NSScreen
    private let completion: (Bool) -> Void
    private var fixtures: [MusicFixture] = []
    private var defaultsControllers: [MusicLyricsController] = []
    private var defaultReaderGate: MusicFixtureGate<Bool, MusicReadResult>?
    private var island: IslandPanelController?
    private var detailPanel: TopEdgePanel?
    private var model: MeterModel?
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private var startedAt: TimeInterval = 0
    private var started = false
    private var finished = false
    private weak var initialKey: NSWindow?
    private var checks = 0
    private var paintedChecks = 0
    private var expandedChecks = 0

    init(screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.screen = screen; self.completion = completion
        super.init()
    }

    func start() {
        guard !started, !finished else { return }
        started = true; startedAt = CACurrentMediaTime(); initialKey = NSApp.keyWindow
        guard CommandLine.arguments.contains("--music-test") else { finish(false); return }
        let timer = Timer(timeInterval: 43, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                SmokeDiagnostics.mark("music bounded 43-second deadline exceeded")
                self.finish(false)
            }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
                self.finish(true)
            } catch {
                if let failure = error as? Failure { SmokeDiagnostics.mark("music failed: \(failure.label)") }
                else { SmokeDiagnostics.mark("music cancelled or fixture operation failed") }
                self.finish(false)
            }
        }
    }

    private func run() async throws {
        let primary = makeFixture()
        let model = MeterModel(demo: true, music: primary.controller)
        self.model = model
        try require(model.demo && model.music === primary.controller && primary.controller.synthetic,
                    "demo model uses the injected synthetic music controller")
        primary.controller.start()
        // This exceeds the production non-playing poll interval. An accidental
        // background read cannot pass by merely being scheduled after this check.
        let disabledAt = CACurrentMediaTime()
        try await dwell(3.15)
        let disabledCounts = await countsFor([primary])
        try require(!primary.controller.enabled && !primary.controller.onlineLookupEnabled
            && primary.controller.line.isEmpty && disabledCounts == [[0, 0, 0]],
            "default disabled has no reader, lookup or import calls across ordinary poll interval")
        print("MUSIC_DISABLED_OK: observed=\(decimal(CACurrentMediaTime() - disabledAt)) reads=0 lookups=0 imports=0")
        try await verifySyntheticDefaults()
        try await verifyStartupAndOnlineRevocation()

        primary.controller.setEnabled(true)
        let initial = try await read(primary)
        try require(initial.input, "explicit enable permits exactly its initial authorization attempt")
        try await release(primary, initial, position: 1)
        let ordinary = try await read(primary)
        try require(!ordinary.input && ordinary.startedAt - initial.startedAt >= 0.95,
                    "actual ordinary playing poll never permits a prompt")
        try require((await primary.lookup.calls()).isEmpty, "no online request before opt-in")
        try await release(primary, ordinary, position: 1)
        print("MUSIC_CONSENT_OK: enablePrompt=true ordinaryPrompt=false pollGap=\(decimal(ordinary.startedAt - initial.startedAt)) preOptInLookups=0")

        try await importDocument(primary, text: timedText())
        try await verifyNativeView(primary, model: model)
        // Use real requests for seek corrections, without exposing receive() or
        // changing production polling/line-timer intervals for the harness.
        let seek = try await read(primary)
        try await release(primary, seek, position: 12)
        try await until("forward seek selects the second cue") { primary.controller.line == Self.secondLine }
        let back = try await read(primary)
        try await release(primary, back, position: 1)
        try await until("backward seek restores the first cue") { primary.controller.line == Self.firstLine }
        let pause = try await read(primary)
        // This companion expires during the same real five-second span, with
        // no lyric document and no fabricated unavailable-source response.
        let noDocument = makeFixture()
        noDocument.controller.start(); noDocument.controller.setEnabled(true)
        let emptyRead = try await read(noDocument)
        let noDocumentAt = ProcessInfo.processInfo.systemUptime
        try await release(noDocument, emptyRead, track: "Synthetic No Document", position: 1, observedAt: noDocumentAt)
        let pausedAt = ProcessInfo.processInfo.systemUptime
        try await release(primary, pause, position: 9.9, state: .paused, observedAt: pausedAt)
        try await until("paused sample is applied") { primary.controller.statusText == "已暂停" }
        try await dwell(0.35)
        try require(primary.controller.line == Self.firstLine, "pause does not advance past the next cue")
        print("MUSIC_TIMELINE_OK: forwardSeek=true backwardSeek=true pausedHeld=\(decimal(ProcessInfo.processInfo.systemUptime - pausedAt))")

        // Hold the next real 3-second paused read in flight. The production
        // freshness timer, rather than an injected stale notification, must clear.
        let heldForExpiry = try await read(primary)
        try require(!heldForExpiry.input && heldForExpiry.startedAt - pause.startedAt >= 2.95,
                    "paused polling uses its real three-second interval")
        try await until("five-second freshness expiry clears visible lyrics", timeout: 5.5) {
            primary.controller.line.isEmpty && primary.controller.trackTitle.isEmpty
                && primary.controller.statusText == "Music 播放信息已过期"
        }
        let expiredAge = ProcessInfo.processInfo.systemUptime - pausedAt
        try require(expiredAge >= LyricsTimeline().freshnessInterval && !primary.controller.canImport,
                    "expired playback cannot import or retain a lyric")
        print("MUSIC_STALE_OK: age=\(decimal(expiredAge)) freshness=5 lineEmpty=true titleEmpty=true")
        try await until("no-document source also expires its title") {
            noDocument.controller.line.isEmpty && noDocument.controller.trackTitle.isEmpty
                && noDocument.controller.statusText == "Music 播放信息已过期" && !noDocument.controller.canImport
        }
        let noDocumentCalls = await noDocument.reader.calls().count
        try require(noDocumentCalls >= 2 && !noDocument.controller.hasLocalLyrics,
                    "missing document cannot retain stale title while a real read is pending")
        print("MUSIC_STALE_EMPTY_OK: age=\(decimal(ProcessInfo.processInfo.systemUptime - noDocumentAt)) document=unavailable titleEmpty=true lineEmpty=true")
        noDocument.controller.stop()
        try await release(primary, heldForExpiry, position: 1)
        try await until("fresh source recovers after stale timeout") { primary.controller.line == Self.firstLine }
        let errorRead = try await read(primary)
        try require(await primary.reader.release(errorRead.id, .unavailable(.timedOut)), "deliver source timeout")
        try await until("source error clears every old track and lyric") {
            primary.controller.line.isEmpty && primary.controller.trackTitle.isEmpty && !primary.controller.canImport
        }
        print("MUSIC_SOURCE_OK: reason=timedOut lineEmpty=true titleEmpty=true")

        primary.controller.requestAuthorization()
        let retry = try await read(primary)
        try require(retry.input, "explicit authorization retry permits its own initial prompt")
        try await release(primary, retry, position: 1)
        try await importDocument(primary, text: timedText())
        let deniedRead = try await read(primary)
        try require(!deniedRead.input, "poll after explicit authorization retry is still nonprompting")
        try require(await primary.reader.release(deniedRead.id, .unavailable(.permissionDenied)), "deliver permission denial")
        try await until("denial clears rendered state and requires explicit retry") {
            primary.controller.needsAuthorization && primary.controller.line.isEmpty && primary.controller.trackTitle.isEmpty
        }
        let deniedCalls = await primary.reader.calls().count
        try await dwell(3.15)
        try require(await primary.reader.calls().count == deniedCalls, "denial does not silently poll or prompt again")
        print("MUSIC_DENIED_OK: explicitRetryPrompt=true followupPrompt=false idle=3.15 noAutomaticRetry=true")
        primary.controller.stop()

        try await verifyInvalidPlaybackStates()
        try await verifyTrackRevisionAndLocalReplacement()
        try await verifyRetirement()
        try await verifyCleanup()
        try require(paintedChecks == 1 && expandedChecks == 2 && checks >= 40,
                    "all native paint, geometry and lifecycle observations completed")
    }

    private func verifySyntheticDefaults() async throws {
        let inert = MusicLyricsController(synthetic: true)
        defaultsControllers.append(inert)
        inert.start(); inert.setOnlineLookupEnabled(true); inert.setEnabled(true)
        try await until("uninjected synthetic controller uses the silent reader") {
            inert.statusText == "请打开 Music 并播放歌曲"
        }
        inert.importLyrics(from: URL(fileURLWithPath: "/synthetic-never-opened.lrc"), for: UUID())
        try require(inert.line.isEmpty && inert.trackTitle.isEmpty && !inert.canImport && !inert.hasLocalLyrics,
                    "synthetic defaults remain fail closed even with both toggles enabled")
        inert.stop()
        // Also reach the default lookup/import closures using only an injected
        // reader. Both must reject without ever opening the synthetic URL.
        let gate = MusicFixtureGate<Bool, MusicReadResult>()
        defaultReaderGate = gate
        let readerOnly = MusicLyricsController(synthetic: true, reader: MusicFixtureReader(gate: gate))
        defaultsControllers.append(readerOnly)
        readerOnly.start(); readerOnly.setEnabled(true)
        let request = try await next(gate, after: 0)
        try require(await gate.release(request.id, snapshot(position: 1)), "deliver reader-only synthetic fixture")
        try await until("reader-only default controller receives fresh source") { readerOnly.canImport }
        readerOnly.setOnlineLookupEnabled(true)
        try await until("uninjected synthetic lookup rejects") { readerOnly.statusText == "在线歌词暂不可用，可导入本地 LRC" }
        try beginImport(readerOnly, path: "/synthetic-never-opened.lrc")
        try await until("uninjected synthetic importer rejects") {
            readerOnly.statusText == "无法读取所选歌词，请选择有效的 UTF-8 LRC 或文本文件"
        }
        try require(readerOnly.line.isEmpty && !readerOnly.hasLocalLyrics, "no production fallback on absent synthetic injection")
        readerOnly.stop(); await gate.releaseAll(.unavailable(.cancelled))
        print("MUSIC_SYNTHETIC_OK: defaultReader=silent defaultLookup=reject defaultImporter=reject")
    }

    private func verifyStartupAndOnlineRevocation() async throws {
        let fixture = makeFixture()
        fixture.controller.setEnabled(true)
        try require((await fixture.reader.calls()).isEmpty, "enabled before start never polls early")
        fixture.controller.start()
        let startup = try await read(fixture)
        try require(!startup.input, "restored-enabled startup never authorizes a permission prompt")
        try await release(fixture, startup, position: 1)
        fixture.controller.setOnlineLookupEnabled(true)
        let request = try await lookup(fixture)
        try require(request.input.consent, "online request is reached only after explicit opt-in")
        fixture.controller.setOnlineLookupEnabled(false)
        try await until("online-only revocation cancels its pending lookup") { await fixture.lookup.cancelledIDs().contains(request.id) }
        try require(await fixture.lookup.release(request.id, .matched(document("[00:00]\(Self.obsoleteLine)"))),
                    "deliver a late result after only online consent is revoked")
        try await until("revoked online result really returns") { await fixture.lookup.returnedIDs().contains(request.id) }
        try await dwell(0.10)
        try require(fixture.controller.enabled && !fixture.controller.onlineLookupEnabled && fixture.controller.line.isEmpty,
                    "revoking only online consent rejects the late lyric while music stays enabled")
        try await importDocument(fixture, text: timedText())
        fixture.controller.setOnlineLookupEnabled(true); fixture.controller.setOnlineLookupEnabled(false)
        try await dwell(0.10)
        let lookupCount = await fixture.lookup.calls().count
        try require(fixture.controller.line == Self.firstLine && fixture.controller.hasLocalLyrics
            && lookupCount == 1, "local lyrics survive online-off and suppress replacement lookup")
        print("MUSIC_STARTUP_OK: enabledBeforeStart=true readsBeforeStart=0 startupPrompt=false")
        print("MUSIC_ONLINE_OFF_OK: pendingCancelled=true lateRejected=true localPreserved=true musicEnabled=true")
        fixture.controller.stop()
    }

    private func verifyInvalidPlaybackStates() async throws {
        let states: [(String, MusicPlaybackState)] = [("unknown", .unknown), ("stopped", .stopped)]
        let values = states.map { _ in makeFixture() }
        for value in values {
            value.controller.start(); value.controller.setEnabled(true)
            let first = try await read(value); try await release(value, first, position: 1)
            try await importDocument(value, text: timedText())
            try require(value.controller.line == Self.firstLine, "invalid-state test starts with a displayed lyric")
        }
        for (index, value) in values.enumerated() {
            let request = try await read(value)
            try require(await value.reader.release(request.id, snapshot(position: 1, state: states[index].1)),
                        "deliver fresh invalid playback state through a real poll")
            try await until("unknown or stopped state clears lyric and track") {
                value.controller.line.isEmpty && value.controller.trackTitle.isEmpty && !value.controller.canImport
            }
            print("MUSIC_STATE_OK: kind=\(states[index].0) freshSample=true previousLine=true cleared=true")
            value.controller.stop()
        }
    }

    private func verifyNativeView(_ fixture: MusicFixture, model: MeterModel) async throws {
        guard let geometry = makeGeometry() else { throw Failure(label: "synthetic hosted-screen geometry unavailable") }
        let island = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            hovered: {}, refresh: {}, settings: {}, quit: {})
        self.island = island
        let openedAt = CACurrentMediaTime()
        try require(island.beginSmokeExpansion(), "synthetic pointer opens existing island")
        try await until("expanded normal-run-loop viewport settles") { self.nativeSettled(island, progress: 1, after: openedAt) }
        try await dwell(0.15)
        try verifyExpanded(island)
        let raster = try ownViewImage(island)
        guard let text = await MusicRasterOCR.recognize(raster.image) else { throw Failure(label: "bounded local lyric OCR failed") }
        try require(contains(text, Self.firstLine), "original lyric is painted in real CompactDetailView pixels")
        paintedChecks += 1
        print("MUSIC_PAINT_OK: view=CompactDetailView originalLine=true width=\(raster.width) height=\(raster.height) scale=\(decimal(screen.backingScaleFactor))")

        // A real quota notice must own the panel even while lyric state changes.
        let collapsedAt = CACurrentMediaTime(); island.collapse()
        try await until("native panel collapses before quota notice") { self.nativeSettled(island, progress: 0, after: collapsedAt) }
        let fresh = try await read(fixture)
        try await release(fixture, fresh, position: 1)
        let notice = try makeNotice()
        try require(island.showRefreshNotice(notice), "real refresh notice accepts changed numeric quota")
        try await until("quota notice receives native painted readiness") {
            island.smokeNoticeTargetActive && island.smokeNoticeID == notice.id
                && island.smokeNoticeArmedAt != nil && island.smokeNoticePaintReadyAt != nil
                && island.smokeProgress == geometry.updateProgress && !island.smokeMotionRunning
        }
        let armed = island.smokeNoticeArmedAt, painted = island.smokeNoticePaintReadyAt
        let frame = island.panel.frame
        try await importDocument(fixture, text: "[00:00]\(Self.localLine)")
        try await dwell(0.15)
        try require(island.smokeNoticeID == notice.id && island.smokeNoticeTargetActive
            && island.smokeNoticeArmedAt == armed && island.smokeNoticePaintReadyAt == painted
            && island.smokeProgress == geometry.updateProgress && island.panel.frame == frame
            && island.panel.ignoresMouseEvents && !island.isInteracting,
            "lyric replacement neither replaces quota notice nor changes geometry, expiry or click routing")
        print("MUSIC_PRIORITY_OK: actualRefreshNotice=true lyricChanged=true noticeRetained=true passive=true")
        let promotedAt = CACurrentMediaTime()
        try require(island.beginSmokeExpansion(), "quota notice promotes to details through the normal hover path")
        try await until("promoted expanded viewport settles") { self.nativeSettled(island, progress: 1, after: promotedAt) }
        try await dwell(0.15)
        try verifyExpanded(island)
        try require(!island.smokeNoticeTargetActive && !island.smokeNoticeVisible && island.smokeNoticeArmedAt == nil,
                    "hover promotion retires notice and expiry without losing expanded Quit")
        print("MUSIC_LAYOUT_OK: nativeExpanded=2 measuredQuit=2 clickRouting=2 nonactivating=true")
        try await verifyLongDetailLayout(fixture, model: model, island: island)
        // Restore the three-cue original fixture for the real seek/pause tests.
        try await importDocument(fixture, text: timedText())
    }

    private func verifyLongDetailLayout(_ fixture: MusicFixture, model: MeterModel, island: IslandPanelController) async throws {
        guard let original = model.snapshot else { throw Failure(label: "missing demo quota fixture") }
        let now = Date()
        let many = QuotaSnapshot(buckets: (0..<4).map { index in
            QuotaBucket(id: "synthetic-music-\(index)", name: "Synthetic quota \(index + 1)", windows: [
                QuotaWindow(id: "\(index)-short", usedPercent: 28, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                QuotaWindow(id: "\(index)-long", usedPercent: 46, durationMinutes: 10080, resetsAt: now.addingTimeInterval(7200))
            ])
        }, fetchedAt: now)
        model.setUpdateFixture(many)
        try require(model.snapshot?.buckets.count == 4, "many-quota fixture reaches existing demo views")
        var quitFrame = CGRect.zero
        let hosting = NSHostingView(rootView: DetailView(model: model, quitFrameChanged: { quitFrame = $0 },
            hovered: { _ in }, refresh: {}, settings: {}, quit: {}))
        hosting.sizingOptions = []
        let frame = CGRect(x: screen.frame.midX - 170, y: screen.frame.midY - 295, width: 340, height: 590)
        let panel = TopEdgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        detailPanel = panel
        panel.isReleasedWhenClosed = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hidesOnDeactivate = false
        panel.contentView = hosting; panel.orderFrontRegardless()
        try await until("existing DetailView measures its native footer") { quitFrame.width > 20 && quitFrame.height >= 20 }
        try await dwell(0.15)
        let baseline = quitFrame
        let longLine = "Silver lanterns follow the tide while amber windows welcome the rain along the quiet harbor"
        try await importDocument(fixture, text: "[00:00]\(longLine)")
        try await until("long original lyric reaches the actual rows") { fixture.controller.line == longLine }
        try await dwell(0.20)
        let viewport = CGRect(origin: .zero, size: hosting.bounds.size)
        try require(panel.isVisible && panel.frame.size == CGSize(width: 340, height: 590)
            && viewport.contains(quitFrame) && quitFrame.width > 20 && quitFrame.height >= 20
            && abs(quitFrame.minY - baseline.minY) < 0.5 && abs(quitFrame.height - baseline.height) < 0.5
            && hosting.fittingSize.height <= 590 && !panel.isKeyWindow && NSApp.keyWindow === initialKey,
            "long lyric and eight quota rows keep real DetailView Quit within the production popover cap")
        try require(island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting(),
                    "long lyric and many quotas preserve existing compact footer and routing")
        print("MUSIC_LONG_LAYOUT_OK: view=DetailView quotaRows=8 longLyric=true footerUnchanged=true quitContained=true compactQuit=true")
        panel.orderOut(nil); panel.close(); detailPanel = nil
        model.setUpdateFixture(original)
    }

    private func verifyTrackRevisionAndLocalReplacement() async throws {
        let fixture = makeFixture()
        fixture.controller.start(); fixture.controller.setOnlineLookupEnabled(true); fixture.controller.setEnabled(true)
        let a1 = try await read(fixture); try await release(fixture, a1, position: 1)
        let oldA = try await lookup(fixture)
        guard let originalSelection = fixture.controller.importSelectionToken else { throw Failure(label: "missing A file-picker token") }
        let b = try await read(fixture); try await release(fixture, b, track: "Synthetic B", position: 1)
        let oldB = try await lookup(fixture)
        fixture.controller.importLyrics(from: URL(fileURLWithPath: "/synthetic-old-picker.lrc"), for: originalSelection)
        try await dwell(0.10)
        try require((await fixture.importer.calls()).isEmpty, "A file-picker selection cannot import into B")
        let a2 = try await read(fixture); try await release(fixture, a2, position: 1)
        let newA = try await lookup(fixture)
        fixture.controller.importLyrics(from: URL(fileURLWithPath: "/synthetic-old-picker.lrc"), for: originalSelection)
        try await dwell(0.10)
        try require((await fixture.importer.calls()).isEmpty && fixture.controller.importSelectionToken != originalSelection,
                    "A file-picker selection cannot import into a later A revision")
        print("MUSIC_PICKER_OK: staleAtoB=blocked staleAtoBtoA=blocked importerCalls=0")
        try require(oldA.input.track == newA.input.track && oldA.input.track != oldB.input.track
            && oldA.input.consent && oldB.input.consent && newA.input.consent,
            "A to B to A really reuses identity and issues three opted-in lookups")
        try require(await fixture.lookup.release(newA.id, .matched(document(timedText()))), "complete newest A lookup")
        try await until("newest A lookup is displayed") { fixture.controller.line == Self.firstLine }
        try require(await fixture.lookup.release(oldA.id, .matched(document("[00:00]\(Self.obsoleteLine)"))), "deliver cancelled old A result after new A")
        try require(await fixture.lookup.release(oldB.id, .matched(document("[00:00]\(Self.obsoleteLine)"))), "deliver cancelled old B result after new A")
        try await until("old track work receives cancellation and actually returns") {
            let cancelled = await fixture.lookup.cancelledIDs().isSuperset(of: [oldA.id, oldB.id])
            let returned = await fixture.lookup.returnedIDs().isSuperset(of: [oldA.id, oldB.id])
            return cancelled && returned
        }
        try await dwell(0.10)
        try require(fixture.controller.line == Self.firstLine && fixture.controller.trackTitle == "Synthetic A",
                    "delayed A and B cannot overwrite the replacement A revision")
        print("MUSIC_REVISION_OK: sequence=A-B-A lookups=3 cancelledOld=2 newestLineRetained=true")

        // Two user imports for the same track finish in reverse order.
        try beginImport(fixture.controller, path: "/synthetic-first.lrc")
        let oldImport = try await imported(fixture)
        try beginImport(fixture.controller, path: "/synthetic-second.lrc")
        let newImport = try await imported(fixture)
        try require(await fixture.importer.release(newImport.id, document("[00:00]\(Self.localLine)")), "complete newest local import")
        try await until("new local import replaces online result") { fixture.controller.line == Self.localLine && fixture.controller.hasLocalLyrics }
        try require(await fixture.importer.release(oldImport.id, document("[00:00]\(Self.obsoleteLine)")), "deliver superseded local import")
        try await until("superseded import cancellation and return observed") {
            let cancelled = await fixture.importer.cancelledIDs().contains(oldImport.id)
            let returned = await fixture.importer.returnedIDs().contains(oldImport.id)
            return cancelled && returned
        }
        try await dwell(0.10)
        try require(fixture.controller.line == Self.localLine && fixture.controller.sourceLabel == "本地歌词",
                    "late older import cannot replace selected local lyrics")

        // A new pending online lookup is cancelled by a successful local import.
        fixture.controller.clearLocalLyrics()
        let pendingOnline = try await lookup(fixture)
        try await importDocument(fixture, text: "[00:00]\(Self.localLine)")
        try await until("local import cancels pending online lookup") { await fixture.lookup.cancelledIDs().contains(pendingOnline.id) }
        try require(await fixture.lookup.release(pendingOnline.id, .matched(document("[00:00]\(Self.obsoleteLine)"))), "deliver late online result after local import")
        try await until("late online response actually returns") { await fixture.lookup.returnedIDs().contains(pendingOnline.id) }
        try await dwell(0.10)
        try require(fixture.controller.line == Self.localLine && fixture.controller.hasLocalLyrics,
                    "late online work cannot replace local selection")
        print("MUSIC_IMPORT_OK: reversedImports=2 cancelledOld=true localWinsOverLateOnline=true")
        fixture.controller.stop()
    }

    private func verifyRetirement() async throws {
        // Run these independent fixtures concurrently. Each owns a real pending
        // poll, lookup and import before retirement. Gates deliberately ignore
        // cancellation until released, exposing unsafe late-result acceptance.
        let names = ["disable", "sleep", "stop"]
        let values = names.map { _ in makeFixture() }
        let visible = names.map { _ in makeFixture() }
        for value in visible {
            value.controller.start(); value.controller.setEnabled(true)
            let initial = try await read(value); try await release(value, initial, position: 1)
            try await importDocument(value, text: timedText())
            try require(value.controller.line == Self.firstLine, "retirement starts with a genuinely visible lyric")
        }
        for value in values {
            value.controller.start(); value.controller.setOnlineLookupEnabled(true); value.controller.setEnabled(true)
        }
        var pending: [(MusicFixtureCall<Bool>, MusicFixtureCall<MusicLookupInput>, MusicFixtureCall<URL>)] = []
        for value in values {
            let initial = try await read(value); try await release(value, initial, position: 1)
            let online = try await lookup(value)
            try beginImport(value.controller, path: "/synthetic-retired.lrc")
            let local = try await imported(value)
            let polling = try await read(value)
            pending.append((polling, online, local))
        }
        for group in [values, visible] {
            for (index, value) in group.enumerated() {
                switch index {
                case 0: value.controller.setEnabled(false)
                case 1: value.controller.setActive(false)
                default: value.controller.stop()
                }
            }
        }
        for value in visible {
            try require(value.controller.line.isEmpty && value.controller.trackTitle.isEmpty && !value.controller.canImport,
                        "retirement immediately clears previously displayed lyric and source")
        }
        for (index, value) in values.enumerated() {
            let held = pending[index]
            try await until("\(names[index]) cancels reader, lookup and importer") {
                let reader = await value.reader.cancelledIDs().contains(held.0.id)
                let lookup = await value.lookup.cancelledIDs().contains(held.1.id)
                let importer = await value.importer.cancelledIDs().contains(held.2.id)
                return reader && lookup && importer
            }
            try require(await value.reader.release(held.0.id, snapshot(position: 1)), "release retired poll")
            try require(await value.lookup.release(held.1.id, .matched(document("[00:00]\(Self.obsoleteLine)"))), "release retired lookup")
            try require(await value.importer.release(held.2.id, document("[00:00]\(Self.obsoleteLine)")), "release retired import")
        }
        let counts = await countsFor(values + visible)
        let retiredAt = CACurrentMediaTime()
        try await dwell(3.15)
        try require(await countsFor(values + visible) == counts, "retired controllers never start a new ordinary poll, lookup or import")
        for (index, value) in values.enumerated() {
            try require(value.controller.line.isEmpty && value.controller.trackTitle.isEmpty
                && !value.controller.canImport && !value.controller.hasLocalLyrics,
                "\(names[index]) rejects all released late results")
            print("MUSIC_RETIRE_OK: kind=\(names[index]) readerCancelled=true lookupCancelled=true importCancelled=true visibleCleared=true lateRejected=true quiet=\(decimal(CACurrentMediaTime() - retiredAt))")
        }
        // Wake is an ordinary read, never a renewed authorization prompt. Stop
        // remains terminal even if later lifecycle/toggle methods are invoked.
        let sleeping = values[1]
        sleeping.controller.setActive(true)
        let wake = try await read(sleeping)
        try require(!wake.input, "wake does not authorize a fresh permission prompt")
        try await release(sleeping, wake, position: 1)
        let terminal = values[2]
        terminal.controller.start(); terminal.controller.setActive(true)
        terminal.controller.setEnabled(false); terminal.controller.setEnabled(true)
        terminal.controller.requestAuthorization()
        try await dwell(0.10)
        try require(await terminal.reader.calls().count == counts[2][0], "stop is terminal despite later callbacks")
        print("MUSIC_RESUME_OK: wakePrompt=false stopTerminal=true")
    }

    private func verifyCleanup() async throws {
        for value in fixtures { value.controller.stop() }
        for value in defaultsControllers { value.stop() }
        for value in fixtures {
            await value.reader.releaseAll(.unavailable(.cancelled))
            await value.lookup.releaseAll(.unavailable)
            await value.importer.releaseAll(.unavailable)
        }
        if let gate = defaultReaderGate { await gate.releaseAll(.unavailable(.cancelled)) }
        island?.stop()
        let counts = await countsFor(fixtures)
        try await dwell(0.10)
        var outstanding = 0
        for value in fixtures {
            outstanding += await value.reader.pendingCount()
            outstanding += await value.lookup.pendingCount()
            outstanding += await value.importer.pendingCount()
        }
        try require(outstanding == 0 && island?.smokeStopped == true && detailPanel == nil,
                    "all injected continuations and native windows retire before completion")
        try require(await countsFor(fixtures) == counts, "no fixture resumes external work during orderly cleanup")
        print("MUSIC_CLEANUP_OK: controllers=\(fixtures.count) pendingRequests=0 panelStopped=true")
    }

    private func makeFixture() -> MusicFixture {
        let value = MusicFixture(); fixtures.append(value); return value
    }
    private func timedText() -> String {
        "[00:00]\(Self.firstLine)\n[00:10]\(Self.secondLine)\n[00:20]Morning sails return to the pier"
    }
    private func document(_ text: String) throws -> LyricsDocument { try LRCParser.parse(text) }
    private func snapshot(track: String = "Synthetic A", position: TimeInterval,
                          state: MusicPlaybackState = .playing, observedAt: TimeInterval? = nil) -> MusicReadResult {
        guard let identity = MusicTrackIdentity(title: track, artist: "Original Fixture Ensemble", album: "Native Test Harbor", duration: 120),
              let value = MusicPlaybackSnapshot(track: identity, state: state, position: position,
                observedAt: observedAt ?? ProcessInfo.processInfo.systemUptime) else { return .unavailable(.invalidResponse) }
        return .snapshot(value)
    }
    private func release(_ value: MusicFixture, _ request: MusicFixtureCall<Bool>, track: String = "Synthetic A",
                         position: TimeInterval, state: MusicPlaybackState = .playing, observedAt: TimeInterval? = nil) async throws {
        try require(await value.reader.release(request.id, snapshot(track: track, position: position, state: state, observedAt: observedAt)),
                    "release actual pending synthetic Music request")
        try await until("fresh synthetic track reaches controller") { value.controller.trackTitle == track && value.controller.canImport }
    }
    private func beginImport(_ controller: MusicLyricsController, path: String) throws {
        guard let token = controller.importSelectionToken else { throw Failure(label: "no fresh track for synthetic file selection") }
        controller.importLyrics(from: URL(fileURLWithPath: path), for: token)
    }
    private func importDocument(_ value: MusicFixture, text: String) async throws {
        let result = try document(text)
        try beginImport(value.controller, path: "/synthetic-only.lrc")
        let request = try await imported(value)
        try require(await value.importer.release(request.id, result), "complete injected in-memory import")
        try await until("local import reaches controller") { value.controller.hasLocalLyrics && value.controller.sourceLabel == "本地歌词" }
        // Wait for the importing task, not only a previous hasLocalLyrics value.
        try await until("selected local import completes") { value.controller.statusText != "正在读取所选歌词文件…" }
    }
    private func read(_ value: MusicFixture) async throws -> MusicFixtureCall<Bool> {
        let call = try await next(value.reader, after: value.readCursor)
        value.readCursor = call.id; return call
    }
    private func lookup(_ value: MusicFixture) async throws -> MusicFixtureCall<MusicLookupInput> {
        let call = try await next(value.lookup, after: value.lookupCursor)
        value.lookupCursor = call.id; return call
    }
    private func imported(_ value: MusicFixture) async throws -> MusicFixtureCall<URL> {
        let call = try await next(value.importer, after: value.importCursor)
        value.importCursor = call.id; return call
    }
    private func next<Input: Sendable, Output: Sendable>(_ gate: MusicFixtureGate<Input, Output>, after cursor: Int) async throws -> MusicFixtureCall<Input> {
        var received: MusicFixtureCall<Input>?
        try await until("actual injected request arrives", timeout: 3.6) {
            received = await gate.calls().first(where: { $0.id > cursor }); return received != nil
        }
        guard let received else { throw Failure(label: "missing mock request receipt") }
        return received
    }
    private func countsFor(_ values: [MusicFixture]) async -> [[Int]] {
        var counts: [[Int]] = []
        for value in values {
            counts.append([await value.reader.calls().count, await value.lookup.calls().count, await value.importer.calls().count])
        }
        return counts
    }
    private func until(_ label: String, timeout: TimeInterval = 3.6,
                       condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !finished && !Task.isCancelled && CACurrentMediaTime() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure(label: label)
    }
    private func dwell(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try Task.checkCancellation()
        if finished { throw Failure(label: "harness already retired") }
    }
    private func require(_ valid: Bool, _ label: String) throws {
        checks += 1
        SmokeDiagnostics.mark("music \(label) valid=\(valid)")
        if !valid { throw Failure(label: label) }
    }
    private func decimal(_ value: Double) -> String { String(format: "%.3f", value) }
    private func contains(_ observations: [String], _ expected: String) -> Bool {
        func normalized(_ value: String) -> String { value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        return normalized(observations.joined(separator: " ")).contains(normalized(expected))
    }
    private func makeGeometry() -> IslandGeometry? {
        let frame = screen.frame, width: CGFloat = 220, inset: CGFloat = 32
        let left = frame.midX - width / 2, right = frame.midX + width / 2
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: left - frame.minX, height: inset),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - inset, width: frame.maxX - right, height: inset)) else { return nil }
        return IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor, contentHeight: 260)
    }
    private func nativeSettled(_ island: IslandPanelController, progress: Double, after: TimeInterval) -> Bool {
        let probe = island.motionProbe, expected = island.geometry.frame(progress: progress)
        return probe.visible && probe.nonKey && NSApp.keyWindow === initialKey && island.placementIsValid
            && !probe.running && probe.requestedProgress == progress && probe.renderedProgress == progress
            && probe.renderedAt >= after && probe.frame == expected && probe.viewport == expected.size
            && probe.contentBounds == CGRect(origin: .zero, size: expected.size)
            && probe.layerPresentation == CGRect(origin: .zero, size: expected.size)
            && abs(probe.frame.maxY - screen.frame.maxY) < 0.001
    }
    private func verifyExpanded(_ island: IslandPanelController) throws {
        // Preferences were measured on the ordinary run loop before rasterizing;
        // never force layout to manufacture the Quit/viewport success receipt.
        try require(island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting()
            && NSApp.keyWindow === initialKey && !island.panel.canBecomeKey,
            "native measured Quit remains visible, routed and nonactivating with music")
        expandedChecks += 1
    }
    private func ownViewImage(_ island: IslandPanelController) throws -> (image: CGImage, width: Int, height: Int) {
        guard let view = island.panel.contentView, island.smokeProgress == 1,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(label: "missing own-view bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              abs(CGFloat(bitmap.pixelsWide) - view.bounds.width * screen.backingScaleFactor) <= 2,
              abs(CGFloat(bitmap.pixelsHigh) - view.bounds.height * screen.backingScaleFactor) <= 2 else {
            throw Failure(label: "own-view bitmap has unexpected backing dimensions")
        }
        return (image, bitmap.pixelsWide, bitmap.pixelsHigh)
    }
    private func makeNotice() throws -> RefreshNotice {
        let base = Date().addingTimeInterval(-5), reset = Date().addingTimeInterval(3600)
        func quota(_ used: Double, at date: Date) throws -> QuotaSnapshot {
            let json = "{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)}}}"
            return try QuotaParser.parse(Data(json.utf8), fetchedAt: date)
        }
        var tracker = QuotaUpdateTracker()
        let first = try quota(20, at: base); _ = tracker.record(first, at: base)
        let second = try quota(21, at: Date()), update = tracker.record(second, at: second.fetchedAt)
        guard let notice = RefreshNotice.make(result: update, snapshot: second, preferredBucketID: "codex",
            preferredWindowID: "codex:primary", duration: .long, receivedAt: second.fetchedAt), notice.isEligible else {
            throw Failure(label: "synthetic changed quota did not form eligible notice")
        }
        return notice
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        let elapsed = CACurrentMediaTime() - startedAt
        stop()
        let valid = success && elapsed <= 43 && paintedChecks == 1 && expandedChecks == 2
        print(valid ? "MUSIC_OK: checks=\(checks) elapsed=\(decimal(elapsed)) synthetic=true localViewPixels=true scanout=false"
                    : "MUSIC_FAILED: native synthetic music integration contract failed")
        completion(valid)
    }
    func stop() {
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        island?.stop()
        detailPanel?.orderOut(nil); detailPanel?.close(); detailPanel = nil
        for value in defaultsControllers { value.stop() }
        if let gate = defaultReaderGate { Task { await gate.releaseAll(.unavailable(.cancelled)) } }
        for value in fixtures {
            value.controller.stop()
            Task {
                await value.reader.releaseAll(.unavailable(.cancelled))
                await value.lookup.releaseAll(.unavailable)
                await value.importer.releaseAll(.unavailable)
            }
        }
    }
}

private struct MusicFixtureCall<Input: Sendable>: Sendable {
    let id: Int
    let input: Input
    let startedAt: TimeInterval
}

/// Records real awaited calls. Cancellation is acknowledged but deliberately
/// does not complete the continuation: tests can deliver a maliciously late
/// result and prove the production controller's retirement guards reject it.
private actor MusicFixtureGate<Input: Sendable, Output: Sendable> {
    private var history: [MusicFixtureCall<Input>] = []
    private var pending: [Int: CheckedContinuation<Output, Never>] = [:]
    private var cancelled: Set<Int> = []
    private var returned: Set<Int> = []
    func invoke(_ input: Input) async -> Output {
        let id = history.count + 1
        history.append(MusicFixtureCall(id: id, input: input, startedAt: ProcessInfo.processInfo.systemUptime))
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.recordCancellation(id) }
        }
        returned.insert(id)
        return result
    }
    func calls() -> [MusicFixtureCall<Input>] { history }
    func cancelledIDs() -> Set<Int> { cancelled }
    func returnedIDs() -> Set<Int> { returned }
    func pendingCount() -> Int { pending.count }
    private func recordCancellation(_ id: Int) { cancelled.insert(id) }
    func release(_ id: Int, _ result: Output) -> Bool {
        guard let continuation = pending.removeValue(forKey: id) else { return false }
        continuation.resume(returning: result); return true
    }
    func releaseAll(_ result: Output) {
        let continuations = Array(pending.values); pending.removeAll()
        for continuation in continuations { continuation.resume(returning: result) }
    }
}

private struct MusicFixtureReader: MusicSnapshotProvider {
    let gate: MusicFixtureGate<Bool, MusicReadResult>
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult { await gate.invoke(allowPermissionPrompt) }
}
private struct MusicLookupInput: Sendable {
    let track: LyricsLookupTrack
    let consent: Bool
}
@MainActor
private final class MusicFixture {
    let reader: MusicFixtureGate<Bool, MusicReadResult>
    let lookup: MusicFixtureGate<MusicLookupInput, LyricsLookupResult>
    let importer: MusicFixtureGate<URL, LyricsDocument>
    let controller: MusicLyricsController
    var readCursor = 0
    var lookupCursor = 0
    var importCursor = 0
    init() {
        let reader = MusicFixtureGate<Bool, MusicReadResult>()
        let lookup = MusicFixtureGate<MusicLookupInput, LyricsLookupResult>()
        let importer = MusicFixtureGate<URL, LyricsDocument>()
        self.reader = reader; self.lookup = lookup; self.importer = importer
        controller = MusicLyricsController(synthetic: true, reader: MusicFixtureReader(gate: reader),
            lookup: { track, consent in await lookup.invoke(MusicLookupInput(track: track, consent: consent)) },
            importer: { url in await importer.invoke(url) })
    }
}

private enum MusicRasterOCR {
    /// Vision text recognition is on-device. A timeout resumes independently of
    /// the worker and cancels its request, leaving the main run loop responsive.
    static func recognize(_ image: CGImage) async -> [String]? {
        await withCheckedContinuation { continuation in
            let gate = MusicOCRGate(continuation)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.usesCPUOnly = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    gate.finish(request.results?.compactMap { $0.topCandidates(1).first?.string })
                } catch { gate.finish(nil) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                request.cancel(); gate.finish(nil)
            }
        }
    }
}
private final class MusicOCRGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String]?, Never>?
    init(_ continuation: CheckedContinuation<[String]?, Never>) { self.continuation = continuation }
    func finish(_ result: [String]?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: result)
    }
}
#endif
