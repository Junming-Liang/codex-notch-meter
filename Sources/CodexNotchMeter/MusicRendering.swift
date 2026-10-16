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
    private var passivePanels: [IslandPanelController] = []
    private var passivePaintChecks = 0
    private var legacyLabelChecks = 0
    private var passiveFrameSamples = 0
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
        let timer = Timer(timeInterval: 100, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                SmokeDiagnostics.mark("music bounded 100-second deadline exceeded")
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
        try require(primary.controller.line.isEmpty && !primary.controller.isPlayingForPresentation, "pause removes the lyric instead of retaining the previous cue")
        print("MUSIC_TIMELINE_OK: forwardSeek=true backwardSeek=true pausedCleared=\(decimal(ProcessInfo.processInfo.systemUptime - pausedAt))")

        // Hold the next real 3-second paused read in flight. The production
        // freshness timer, rather than an injected stale notification, must clear.
        let heldForExpiry = try await read(primary)
        try require(!heldForExpiry.input && heldForExpiry.startedAt - pause.startedAt >= 2.95,
                    "paused polling uses its real three-second interval")
        try await until("five-second paused-source freshness expiry clears retained metadata", timeout: 5.5) {
            primary.controller.line.isEmpty && primary.controller.trackTitle.isEmpty
                && primary.controller.statusText == "Music 播放信息已过期" && !primary.controller.isPlayingForPresentation
        }
        let expiredAge = ProcessInfo.processInfo.systemUptime - pausedAt
        try require(expiredAge >= LyricsTimeline().freshnessInterval && !primary.controller.canImport,
                    "expired playback cannot import or retain a lyric")
        print("MUSIC_STALE_OK: age=\(decimal(expiredAge)) freshness=5 lineEmpty=true titleEmpty=true")
        try await until("no-document source also expires its title") {
            noDocument.controller.line.isEmpty && noDocument.controller.trackTitle.isEmpty
                && noDocument.controller.statusText == "Music 播放信息已过期" && !noDocument.controller.canImport
                && !noDocument.controller.isPlayingForPresentation
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
        try await verifyAutomaticPresentation()
        try await verifyLookupStatusRetention()
        try await verifyCleanup()
        try require(paintedChecks == 1 && passivePaintChecks == 5 && legacyLabelChecks == 6 && expandedChecks == 2 && checks >= 100,
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
        try await until("uninjected synthetic lookup rejects") { readerOnly.lookupState == .rejected && readerOnly.statusText == "歌词响应无法安全使用，可导入本地 LRC" }
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
        // Preserve the old manual-details geometry contract independently of the
        // new passive ownership path, which has its own real native phase below.
        island.setMusicPresentationAllowed(false)
        let openedAt = CACurrentMediaTime()
        try require(island.beginSmokeExpansion(), "synthetic pointer opens existing island")
        try await until("expanded normal-run-loop viewport settles") { self.nativeSettled(island, progress: 1, after: openedAt) }
        try await dwell(0.15)
        try verifyExpanded(island)
        let raster = try ownViewImage(island)
        guard let text = await MusicRasterOCR.recognize(raster.image) else { throw Failure(label: "bounded local lyric OCR failed") }
        try verifyNoLegacyLabel(text)
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
            try require(value.controller.line.isEmpty && value.controller.trackTitle.isEmpty && !value.controller.canImport
                && !value.controller.isPlayingForPresentation,
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

    /// All samples use the real injected reader and production 1 s / 3 s polling.
    /// Notice holds are the public 6 s and 4 s choices, measured only after the
    /// existing natural Canvas/readiness gate. No synthetic clock drives motion.
    private func verifyAutomaticPresentation() async throws {
        island?.stop()
        let fixture = makeFixture()
        let model = MeterModel(demo: true, music: fixture.controller)
        let panel = try makePassivePanel(model)
        fixture.controller.start(); fixture.controller.setEnabled(true)
        let initial = try await read(fixture)
        let playingAt = CACurrentMediaTime()
        let observedAt = ProcessInfo.processInfo.systemUptime
        try await release(fixture, initial, position: 1, observedAt: observedAt)
        try await waitMusic(panel, after: playingAt)
        try require(fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty
            && !fixture.controller.hasLocalLyrics && fixture.controller.statusText.contains("LRC"),
            "fresh playing source opens the compact body even without a lyric document")
        let statusPixels = try await compactOCR(panel, languages: ["zh-Hans", "en-US"])
        let titleVisible = contains(statusPixels, "Synthetic A")
        let importStatusVisible = contains(statusPixels, "LRC")
        let obsoleteLyricVisible = contains(statusPixels, Self.firstLine)
        print("MUSIC_AUTO_EMPTY_DIAGNOSTIC: titleVisible=\(titleVisible) importStatusVisible=\(importStatusVisible) obsoleteLyricVisible=\(obsoleteLyricVisible)")
        try require(titleVisible && importStatusVisible && !obsoleteLyricVisible,
                    "no-document compact pixels show the song and honest import status")
        print("MUSIC_AUTO_EMPTY_OK: noHover=true owner=music document=unavailable statusToken=LRC ownViewOCR=true passive=true")

        // Hold the next ordinary read. The real five-second source timer must
        // retire a genuinely visible playing body even with no lyric document.
        let expiredRead = try await read(fixture)
        try await until("visible no-document playing source expires", timeout: 5.5) {
            !fixture.controller.isPlayingForPresentation && fixture.controller.trackTitle.isEmpty
                && fixture.controller.statusText == "Music 播放信息已过期"
        }
        let sourceAge = ProcessInfo.processInfo.systemUptime - observedAt
        try await waitIdle(panel, after: playingAt)
        try require(sourceAge >= 5 && fixture.controller.line.isEmpty && !fixture.controller.canImport,
                    "natural source freshness closes the previously painted no-document body")
        print("MUSIC_AUTO_STALE_OK: age=\(decimal(sourceAge)) document=unavailable previouslyPainted=true owner=idle")
        let recoveredAt = CACurrentMediaTime()
        try await release(fixture, expiredRead, position: 1)
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try await waitMusic(panel, after: recoveredAt)
        try await dwell(0.10)
        let songPixels = try await compactOCR(panel)
        try require(contains(songPixels, Self.firstLine) && !contains(songPixels, "79%")
            && panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                    "native compact body paints the original lyric before notice priority")
        let panelIdentity = ObjectIdentifier(panel.panel)
        let compactFrame = panel.panel.frame
        let steadyRetarget = panel.smokeRetarget?.eventTime
        let steadyFrames = passiveFrameSamples
        for index in 0..<2 {
            let fresh = try await read(fixture); try await release(fixture, fresh, position: 1)
            let expected = index == 0 ? Self.localLine : Self.firstLine
            try await importDocument(fixture, text: "[00:00]\(expected)")
            try await dwell(0.05)
            try require(fixture.controller.line == expected && panel.smokeExpansionOwner == .music
                && panel.smokeRetarget?.eventTime == steadyRetarget && passiveFrameSamples == steadyFrames
                && !panel.smokeMotionRunning && panel.panel.frame == compactFrame,
                "ordinary playing samples and changed lyric content do not restart settled automatic Music motion")
        }
        print("MUSIC_AUTO_STEADY_OK: polls=2 lyricUpdates=2 motionUnchanged=true sameFrame=true")
        let notice = try makeNotice(duration: .long, verifiedContinuity: true)
        try require(panel.showRefreshNotice(notice), "playing compact body accepts an eligible real quota notice")
        try await waitNotice(panel, notice: notice)
        guard let armed = panel.smokeNoticeArmedAt, let painted = panel.smokeNoticePaintReadyAt else {
            throw Failure(label: "missing native notice readiness times")
        }
        let noticeRetarget = panel.smokeRetarget?.eventTime
        let noticeFrames = passiveFrameSamples
        let noticePixels = try await compactOCR(panel)
        try require(contains(noticePixels, "80%") && contains(noticePixels, "79%")
            && !contains(noticePixels, Self.firstLine) && !contains(noticePixels, "Synthetic A"),
            "actual compact pixels replace Music with the 80 to 79 percent quota notice")
        try require(panel.showRefreshNotice(notice), "repeated identical notice is accepted without a new dwell")
        var playingUpdates = 0
        var lyricUpdates = 0
        let deadline = armed + notice.holdDuration + 2
        while panel.smokeNoticeTargetActive && CACurrentMediaTime() < deadline {
            if let request = await fixture.reader.calls().first(where: { $0.id > fixture.readCursor }) {
                fixture.readCursor = request.id
                try await release(fixture, request, position: 1)
                playingUpdates += 1
                let expected = playingUpdates.isMultiple(of: 2) ? Self.firstLine : Self.localLine
                try await importDocument(fixture, text: "[00:00]\(expected)")
                try require(fixture.controller.line == expected, "real lyric replacement reaches the controller during notice dwell")
                lyricUpdates += 1
            }
            if panel.smokeNoticeTargetActive {
                try require(panel.smokeNoticeID == notice.id && panel.smokeNoticeArmedAt == armed
                    && panel.smokeNoticePaintReadyAt == painted && panel.smokeRetarget?.eventTime == noticeRetarget
                    && passiveFrameSamples == noticeFrames && panel.panel.frame == compactFrame
                    && panel.smokeExpansionOwner == .quotaNotice && !panel.smokeMusicTargetActive
                    && panel.panel.ignoresMouseEvents && !panel.isInteracting,
                    "repeated playing and lyric publications cannot reset native notice dwell or motion")
            }
            try await dwell(0.02)
        }
        let held = CACurrentMediaTime() - armed
        try require(!panel.smokeNoticeTargetActive && held >= notice.holdDuration && held <= notice.holdDuration + 1.5
            && playingUpdates >= 2 && lyricUpdates >= 2,
            "real long notice completes all six fully-painted seconds despite repeated Music publications")
        try await waitMusic(panel, after: armed + notice.holdDuration)
        try require(ObjectIdentifier(panel.panel) == panelIdentity && panel.panel.frame == compactFrame
            && !panel.smokeNoticeVisible && fixture.controller.isPlayingForPresentation,
            "notice expiry returns directly to Music in the same compact native panel")
        panel.panel.appearance = NSAppearance(named: .darkAqua)
        try await dwell(0.15)
        let returnPixels = try await compactOCR(panel)
        try require(contains(returnPixels, fixture.controller.line) && !fixture.controller.line.isEmpty
            && !contains(returnPixels, "79%") && contains(returnPixels, "Synthetic A")
            && panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            "own-view pixels prove Music to quota notice to Music content replacement")
        print("MUSIC_AUTO_PRIORITY_OK: hold=\(decimal(held)) expected=6 paintBeforeArm=true playingUpdates=\(playingUpdates) lyricUpdates=\(lyricUpdates) dwellUnchanged=true motionUnchanged=true samePanel=true")
        print("MUSIC_AUTO_PAINT_OK: sequence=music-notice-music lyricBefore=true quota80to79=true lyricAfter=true appearances=aqua,darkAqua width=\(Int(compactFrame.width * screen.backingScaleFactor)) height=\(Int(compactFrame.height * screen.backingScaleFactor)) scale=\(decimal(screen.backingScaleFactor)) localViewPixels=true scanout=false")

        // A pause must hide the lyric immediately, while quota priority completes
        // its already-armed normal dwell before the same panel goes idle.
        let pausedNotice = try makeNotice(duration: .standard)
        try require(panel.showRefreshNotice(pausedNotice), "second normal notice begins from playing Music")
        try await waitNotice(panel, notice: pausedNotice)
        guard let pausedArm = panel.smokeNoticeArmedAt, let pausedPaint = panel.smokeNoticePaintReadyAt else {
            throw Failure(label: "missing paused-notice readiness times")
        }
        let pausedRetarget = panel.smokeRetarget?.eventTime
        let pause = try await read(fixture)
        try await release(fixture, pause, position: 1, state: .paused)
        try await until("real paused sample revokes passive Music") { !fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty }
        try require(panel.smokeNoticeTargetActive && panel.smokeNoticeID == pausedNotice.id
            && panel.smokeNoticeArmedAt == pausedArm && panel.smokeNoticePaintReadyAt == pausedPaint
            && panel.smokeRetarget?.eventTime == pausedRetarget && !panel.smokeMusicTargetActive,
            "pause during quota notice does not clear the notice or restart its deadline")
        try await until("paused notice expires on its original real deadline", timeout: 5) { !panel.smokeNoticeTargetActive }
        let pausedHold = CACurrentMediaTime() - pausedArm
        try await waitIdle(panel, after: pausedArm + pausedNotice.holdDuration)
        try require(pausedHold >= 4 && pausedHold <= 5.5 && fixture.controller.line.isEmpty,
                    "paused notice completes its normal four-second hold then closes without a lyric flash")
        print("MUSIC_AUTO_PAUSE_NOTICE_OK: hold=\(decimal(pausedHold)) expected=4 dwellUnchanged=true lyricEmpty=true owner=idle")

        let resumedAt = CACurrentMediaTime()
        let resume = try await read(fixture); try await release(fixture, resume, position: 1)
        try await waitMusic(panel, after: resumedAt)
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try await enterDetails(panel)
        let hoverPause = try await read(fixture)
        try await release(fixture, hoverPause, position: 1, state: .paused)
        try await until("paused hover keeps details ownership but removes Music") {
            !fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty
                && panel.smokeExpansionOwner == .details && panel.smokeProgress == 1
        }
        try await dwell(0.15)
        let hoverRaster = try ownViewImage(panel)
        guard let pausedPixels = await MusicRasterOCR.recognize(hoverRaster.image) else {
            throw Failure(label: "bounded paused-details OCR failed")
        }
        passivePaintChecks += 1
        try verifyNoLegacyLabel(pausedPixels)
        try require(!contains(pausedPixels, Self.firstLine) && !contains(pausedPixels, "Synthetic A")
            && contains(pausedPixels, "Codex") && panel.verifyExpandedLayout(includePixels: false),
            "paused expanded details retain quota and footer while Music lyric and title disappear from pixels")
        try await exitDetails(panel)
        try await waitIdle(panel, after: resumedAt)
        let nextResumeAt = CACurrentMediaTime()
        let nextResume = try await read(fixture); try await release(fixture, nextResume, position: 1)
        try await waitMusic(panel, after: nextResumeAt)
        try await enterDetails(panel)
        try await exitDetails(panel)
        try await waitMusic(panel, after: nextResumeAt)
        print("MUSIC_AUTO_HOVER_OK: playingExit=music pausedExit=idle pausedDetailsRetained=true pausedLyricAbsentOCR=true realPointerDwell=true")

        // The coordinator's settings/menu gate is exercised directly; no actual
        // Settings window, menu, preferences, or user pointer is opened or moved.
        var closingPaintFrames = 0
        for reason in ["settings", "menu"] {
            let fresh = try await read(fixture); try await release(fixture, fresh, position: 1)
            let suppressedAt = CACurrentMediaTime()
            let initialOpacity = panel.paintReceipt?.frame.surfaceOpacity ?? 0
            panel.setMusicPresentationAllowed(false)
            if reason == "settings" {
                closingPaintFrames = try await observeClosingPaint(panel, after: suppressedAt, initialOpacity: initialOpacity)
            }
            try await waitIdle(panel, after: suppressedAt)
            try require(fixture.controller.isPlayingForPresentation && !panel.smokeMusicTargetActive,
                        "\(reason) suppression prevents passive reopening without changing playback")
            let enabledAt = CACurrentMediaTime()
            panel.setMusicPresentationAllowed(true)
            try await waitMusic(panel, after: enabledAt)
        }
        print("MUSIC_AUTO_SUPPRESS_OK: gates=settings,menu suppressed=idle reenabled=music playbackPreserved=true")
        print("MUSIC_AUTO_CLOSE_PAINT_OK: intermediateFrames=\(closingPaintFrames) opacityDecreased=true opaqueBefore4pt=true idleOpacity=0 naturalPaint=true")
        print("MUSIC_LABEL_OK: compactOCR=4 expandedOCR=2 legacyWordAbsent=true")

        // A pending ordinary read lets a true paused sample arrive during a real
        // close/open reversal. Poll cadence is never shortened to manufacture it.
        let reversingRead = try await read(fixture)
        panel.setMusicPresentationAllowed(false)
        try await until("real compact closing motion begins") {
            panel.smokeMotionRunning && panel.smokeProgress > 0 && panel.smokeProgress < panel.geometry.updateProgress
        }
        panel.setMusicPresentationAllowed(true)
        try require(panel.smokeTargetProgress == panel.geometry.updateProgress && panel.smokeMotionRunning,
                    "reenabling during compact close reverses the existing spring")
        let reversingAt = CACurrentMediaTime()
        try await release(fixture, reversingRead, position: 1, state: .paused)
        try await until("paused sample reverses the reopened target to idle") {
            !fixture.controller.isPlayingForPresentation && panel.smokeTargetProgress == 0
        }
        try require(panel.smokeProgress.isFinite && panel.smokeVelocity.isFinite
            && panel.smokeProgress >= 0 && panel.smokeProgress <= 1 && panel.smokeRetarget != nil,
            "pause during reversal preserves bounded finite motion state")
        try await waitIdle(panel, after: reversingAt)
        print("MUSIC_AUTO_REVERSAL_OK: realPolling=true suppressionReversed=true pauseDuringMotion=true finite=true finalOwner=idle")

        let recreateRead = try await read(fixture); try await release(fixture, recreateRead, position: 1)
        try await waitMusic(panel, after: reversingAt)
        panel.stop()
        let recreatedAt = CACurrentMediaTime()
        let recreated = try makePassivePanel(model)
        try await waitMusic(recreated, after: recreatedAt)
        try require(panel.smokeStopped && recreated.panel !== panel.panel && fixture.controller.isPlayingForPresentation,
                    "recreated native panel inherits playing eligibility without awaiting a new sample")
        print("MUSIC_AUTO_RECREATE_OK: inheritedPlaying=true oldPanelStopped=true noNewSample=true")
        try await verifyPassiveRetirement(fixture, panel: recreated)
        try await verifyReducedMotionPresentation()
    }

    private func verifyPassiveRetirement(_ fixture: MusicFixture, panel: IslandPanelController) async throws {
        var changedAt = CACurrentMediaTime()
        await skipExistingReads(fixture)
        fixture.controller.setActive(false)
        try await waitIdle(panel, after: changedAt)
        try require(!fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty, "sleep retires passive Music")
        fixture.controller.setActive(true)
        let wake = try await read(fixture)
        try require(!wake.input, "passive wake remains nonprompting")
        changedAt = CACurrentMediaTime(); try await release(fixture, wake, position: 1)
        try await waitMusic(panel, after: changedAt)
        await skipExistingReads(fixture)
        changedAt = CACurrentMediaTime(); fixture.controller.setEnabled(false)
        try await waitIdle(panel, after: changedAt)
        fixture.controller.setEnabled(true)
        let enabled = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, enabled, position: 1)
        try await waitMusic(panel, after: changedAt)
        let denied = try await read(fixture)
        changedAt = CACurrentMediaTime()
        try require(await fixture.reader.release(denied.id, .unavailable(.permissionDenied)), "deliver passive permission denial")
        try await waitIdle(panel, after: changedAt)
        try require(fixture.controller.needsAuthorization && !fixture.controller.isPlayingForPresentation,
                    "permission denial immediately retires passive Music")
        fixture.controller.requestAuthorization()
        let authorized = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, authorized, position: 1)
        try await waitMusic(panel, after: changedAt)
        let stoppedRead = try await read(fixture)
        changedAt = CACurrentMediaTime()
        try require(await fixture.reader.release(stoppedRead.id, snapshot(position: 1, state: .stopped)), "deliver stopped playback")
        try await waitIdle(panel, after: changedAt)
        try require(!fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty,
                    "stopped playback removes passive Music")
        fixture.controller.requestAuthorization()
        let again = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, again, position: 1)
        try await waitMusic(panel, after: changedAt)
        changedAt = CACurrentMediaTime(); fixture.controller.stop()
        try await waitIdle(panel, after: changedAt)
        try require(!fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty, "terminal stop removes passive Music")
        panel.stop()
        print("MUSIC_AUTO_RETIRE_OK: disable=idle sleep=idle permission=idle stoppedPlayback=idle controllerStop=idle wakePrompt=false")
    }

    private func verifyReducedMotionPresentation() async throws {
        let fixture = makeFixture()
        let model = MeterModel(demo: true, music: fixture.controller)
        let panel = try makePassivePanel(model, reducedMotion: true)
        let frames = passiveFrameSamples
        fixture.controller.start(); fixture.controller.setEnabled(true)
        let initial = try await read(fixture)
        let openedAt = CACurrentMediaTime(); try await release(fixture, initial, position: 1)
        try await waitMusic(panel, after: openedAt)
        try require(!panel.smokeMotionRunning && panel.smokeVelocity == 0 && passiveFrameSamples == frames,
                    "Reduce Motion opens automatic Music without a motion source")
        let notice = try makeNotice(duration: .short)
        try require(panel.showRefreshNotice(notice), "Reduce Motion retains quota priority")
        try await waitNotice(panel, notice: notice)
        guard let armed = panel.smokeNoticeArmedAt else { throw Failure(label: "Reduce Motion notice never armed") }
        let refresh = try await read(fixture); try await release(fixture, refresh, position: 1)
        try await until("Reduce Motion notice completes its normal two-second hold", timeout: 3) { !panel.smokeNoticeTargetActive }
        let held = CACurrentMediaTime() - armed
        try await waitMusic(panel, after: armed + notice.holdDuration)
        let pause = try await read(fixture)
        let pausedAt = CACurrentMediaTime(); try await release(fixture, pause, position: 1, state: .paused)
        try await waitIdle(panel, after: pausedAt)
        try require(held >= 2 && held <= 3.5 && !panel.smokeMotionRunning && panel.smokeVelocity == 0
            && passiveFrameSamples == frames && fixture.controller.line.isEmpty,
            "Reduce Motion notice returns to Music then pause reaches idle without animation frames")
        fixture.controller.stop(); panel.stop()
        print("MUSIC_AUTO_REDUCED_OK: hold=\(decimal(held)) expected=2 sequence=music-notice-music-idle motionFrames=0 passive=true")
    }

    private func makePassivePanel(_ model: MeterModel, reducedMotion: Bool = false) throws -> IslandPanelController {
        guard let geometry = makeGeometry() else { throw Failure(label: "missing automatic Music geometry") }
        let value = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: reducedMotion, motionSample: { [weak self] _ in self?.passiveFrameSamples += 1 },
            hovered: {}, refresh: {}, settings: {}, quit: {})
        value.panel.appearance = NSAppearance(named: .aqua)
        passivePanels.append(value)
        return value
    }
    private func waitMusic(_ panel: IslandPanelController, after: TimeInterval) async throws {
        try await until("native compact Music settles with fresh natural paint") {
            self.nativeSettled(panel, progress: panel.geometry.updateProgress, after: after)
                && panel.smokeExpansionOwner == .music && panel.smokeMusicTargetActive && panel.smokeMusicVisible
                && !panel.smokeNoticeTargetActive && !panel.isInteracting && panel.panel.ignoresMouseEvents
                && self.naturalPaintMatches(panel, progress: panel.geometry.updateProgress, after: after)
        }
        try require((panel.paintReceipt?.frame.surfaceOpacity ?? 0) > 0,
                    "native compact Music has a painted body after notice or motion transition")
    }
    private func waitIdle(_ panel: IslandPanelController, after: TimeInterval) async throws {
        try await until("native automatic Music closes to painted idle") {
            self.nativeSettled(panel, progress: 0, after: after) && panel.smokeExpansionOwner == .idle
                && !panel.smokeMusicTargetActive && !panel.smokeMusicVisible && !panel.smokeNoticeVisible
                && panel.panel.ignoresMouseEvents && self.naturalPaintMatches(panel, progress: 0, after: after)
        }
        try require(panel.paintReceipt?.frame.surfaceOpacity == 0,
                    "actual idle paint has no remaining black body opacity")
    }
    private func waitNotice(_ panel: IslandPanelController, notice: RefreshNotice) async throws {
        try await until("native quota priority receives its own natural painted readiness") {
            guard let armed = panel.smokeNoticeArmedAt, let painted = panel.smokeNoticePaintReadyAt else { return false }
            return panel.smokeNoticeID == notice.id && panel.smokeNoticeTargetActive
                && panel.smokeExpansionOwner == .quotaNotice && !panel.smokeMusicTargetActive && painted <= armed
                && self.nativeSettled(panel, progress: panel.geometry.updateProgress, after: painted - 0.25)
                && self.naturalPaintMatches(panel, progress: panel.geometry.updateProgress, after: painted)
        }
    }
    private func naturalPaintMatches(_ panel: IslandPanelController, progress: Double, after: TimeInterval) -> Bool {
        guard let receipt = panel.paintReceipt else { return false }
        let expected = panel.geometry.frame(progress: progress)
        return receipt.observed >= after && receipt.frame.progress == progress
            && receipt.frame.viewport == expected.size && receipt.actualViewport == expected.size
            && receipt.frame.noticeID == panel.smokeNoticeID
            && abs(receipt.frame.surfaceOpacity - panel.geometry.surfaceOpacity(progress: progress)) < 0.000001
    }
    private func compactOCR(_ panel: IslandPanelController, languages: [String] = ["zh-Hans", "en-US"]) async throws -> [String] {
        // Readiness is checked before caching. A cache render proves content but
        // cannot manufacture natural-run-loop or physical-scanout readiness.
        try require(nativeSettled(panel, progress: panel.geometry.updateProgress, after: 0)
            && naturalPaintMatches(panel, progress: panel.geometry.updateProgress, after: 0),
            "compact own-view capture follows independently observed native readiness")
        let raster = try ownViewImage(panel, progress: panel.geometry.updateProgress)
        // This harness owns only original synthetic song/text fixtures. Keep the
        // unchanged native-size capture available when OCR fails, without ever
        // capturing the screen, Music.app or a live user's metadata.
        let directory = URL(fileURLWithPath: "dist/contour-rendering/music", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = String(format: "compact-%02d.png", passivePaintChecks + 1)
        guard let png = NSBitmapImageRep(cgImage: raster.image).representation(using: .png, properties: [:]) else {
            throw Failure(label: "cannot encode synthetic compact own-view evidence")
        }
        try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
        guard let observations = await MusicRasterOCR.recognize(raster.image, languages: languages) else {
            throw Failure(label: "bounded compact Music OCR failed")
        }
        let diagnostic: [String: Any] = ["fixture": "original-synthetic-only", "image": filename,
            "width": raster.width, "height": raster.height, "progress": panel.smokeProgress,
            "scale": screen.backingScaleFactor, "observations": observations,
            "appearance": panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"]
        let diagnosticJSON = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        print("MUSIC_COMPACT_OCR_DIAGNOSTIC: \(String(decoding: diagnosticJSON, as: UTF8.self))")
        passivePaintChecks += 1
        try verifyNoLegacyLabel(observations)
        return observations
    }
    private func verifyNoLegacyLabel(_ observations: [String]) throws {
        let characters = observations.joined().filter { !$0.isWhitespace }
        try require(!characters.contains("刘海"), "own-view mixed-language OCR contains no removed legacy island label")
        legacyLabelChecks += 1
    }
    private func observeClosingPaint(_ panel: IslandPanelController, after: TimeInterval, initialOpacity: Double) async throws -> Int {
        var fadeSequences: Set<UInt64> = []
        var opaqueSequences: Set<UInt64> = []
        var opacityMatchesGeometry = true
        try await until("real Music closing paint reaches idle") {
            if let paint = panel.paintReceipt, paint.observed >= after,
               paint.frame.progress > 0 && paint.frame.progress < panel.geometry.updateProgress {
                let expected = panel.geometry.frame(progress: paint.frame.progress).size
                if paint.actualViewport == expected && paint.frame.viewport == expected {
                    let residual = panel.geometry.contourResidual(progress: paint.frame.progress)
                    let opacity = paint.frame.surfaceOpacity
                    opacityMatchesGeometry = opacityMatchesGeometry
                        && abs(opacity - panel.geometry.surfaceOpacity(progress: paint.frame.progress)) < 0.000001
                    if residual >= 4 {
                        opaqueSequences.insert(paint.sequence)
                        opacityMatchesGeometry = opacityMatchesGeometry && opacity == 1
                    } else if residual > 0 && opacity >= 0 && opacity < initialOpacity {
                        fadeSequences.insert(paint.sequence)
                    }
                }
            }
            return panel.smokeProgress == 0 && !panel.smokeMotionRunning
        }
        try require(initialOpacity > 0 && !fadeSequences.isEmpty && !opaqueSequences.isEmpty && opacityMatchesGeometry,
                    "natural Music close remains opaque outside four points and fades with its real contour residual")
        return fadeSequences.count
    }
    private func enterDetails(_ panel: IslandPanelController) async throws {
        let began = CACurrentMediaTime()
        panel.smokePointer(inside: true, now: ProcessInfo.processInfo.systemUptime)
        try await dwell(0.14)
        panel.smokePointer(inside: true, now: ProcessInfo.processInfo.systemUptime)
        try await until("real hover promotes automatic Music to native details") {
            panel.smokeExpansionOwner == .details && self.nativeSettled(panel, progress: 1, after: began)
        }
        try require(panel.verifyExpandedLayout(includePixels: false) && panel.verifySmokeClickRouting(),
                    "automatic Music hover preserves native footer routing")
    }
    private func exitDetails(_ panel: IslandPanelController) async throws {
        panel.smokePointer(inside: false, now: ProcessInfo.processInfo.systemUptime)
        try await dwell(0.24)
        panel.smokePointer(inside: false, now: ProcessInfo.processInfo.systemUptime)
        try require(!panel.isInteracting, "real hover exit hysteresis relinquishes details ownership")
    }

    private func verifyLookupStatusRetention() async throws {
        let values = [makeFixture(lookupFailure: .serviceUnavailable(retryAfter: 60)), makeFixture(),
            makeFixture(), makeFixture(lookupFailure: .identityMismatch)]
        let states: [LyricsLookupState] = [.serviceUnavailable, .noMatch, .unavailable, .identityMismatch]
        let labels = ["serviceUnavailable", "noMatch", "unavailable", "identityMismatch"]
        let statuses = ["歌词服务暂不可用，可稍后重试或导入本地 LRC", "未找到匹配歌词，可导入本地 LRC",
            "匹配记录暂无可用歌词，可导入本地 LRC", "匹配结果版本不一致，可导入本地 LRC"]
        let began = CACurrentMediaTime()
        for value in values {
            value.controller.start(); value.controller.setOnlineLookupEnabled(true); value.controller.setEnabled(true)
            let initial = try await read(value); try await release(value, initial, position: 1)
        }
        for (index, value) in values.enumerated() {
            let request = try await lookup(value)
            // Failure fixtures throw only after this explicit gate completes;
            // there is no network request and no fabricated successful match.
            try require(await value.lookup.release(request.id, index == 1 ? .noMatch : .unavailable),
                        "deliver injected \(labels[index]) lookup result")
            try await until("distinct lookup outcome is visible") {
                value.controller.lookupState == states[index] && value.controller.statusText == statuses[index]
            }
        }
        for _ in 0..<3 {
            for value in values {
                let request = try await read(value); try await release(value, request, position: 1)
            }
            try await dwell(0.04)
            for (index, value) in values.enumerated() {
                let lookupCount = await value.lookup.calls().count
                try require(value.controller.lookupState == states[index] && value.controller.statusText == statuses[index]
                    && value.controller.isPlayingForPresentation && value.controller.line.isEmpty
                    && lookupCount == 1,
                    "same-track real polls preserve \(labels[index]) and do not repeat lookup")
            }
        }
        for value in values.dropFirst() { value.controller.stop() }
        let transient = values[0]
        let unavailable = try await read(transient)
        try require(await transient.reader.release(unavailable.id, .unavailable(.timedOut)), "interrupt Music source during service cooldown")
        try await until("Music source interruption clears old source") {
            !transient.controller.isPlayingForPresentation && transient.controller.trackTitle.isEmpty
        }
        let recovered = try await read(transient); try await release(transient, recovered, position: 1)
        try await until("same track recovery restores temporary service status without a lookup") {
            transient.controller.isPlayingForPresentation && transient.controller.lookupState == .serviceUnavailable
                && transient.controller.statusText == statuses[0]
        }
        try require(await transient.lookup.calls().count == 1, "Music source interruption cannot bypass service cooldown")
        print("MUSIC_LOOKUP_RECOVERY_OK: source=timedOut freshSameTrack=true state=serviceUnavailable lookupCalls=1 cooldownPreserved=true")
        let observed = CACurrentMediaTime() - began
        try require(observed >= 3 && observed < 60, "service cooldown observation spans three real polls without waiting or skipping sixty seconds")
        for value in values { value.controller.stop() }
        print("MUSIC_LOOKUP_STATUS_OK: states=serviceUnavailable,noMatch,unavailable,identityMismatch polls=3 lookupCalls=1 fixedStatus=true noFalseNoMatch=true")
        print("MUSIC_LOOKUP_COOLDOWN_OK: observed=\(decimal(observed)) retryAfter=60 polls=3 lookupCalls=1 synthetic=true")
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
        for panel in passivePanels { panel.stop() }
        let counts = await countsFor(fixtures)
        try await dwell(0.10)
        var outstanding = 0
        for value in fixtures {
            outstanding += await value.reader.pendingCount()
            outstanding += await value.lookup.pendingCount()
            outstanding += await value.importer.pendingCount()
        }
        try require(outstanding == 0 && island?.smokeStopped == true && passivePanels.allSatisfy(\.smokeStopped) && detailPanel == nil,
                    "all injected continuations and native windows retire before completion")
        try require(await countsFor(fixtures) == counts, "no fixture resumes external work during orderly cleanup")
        print("MUSIC_CLEANUP_OK: controllers=\(fixtures.count) pendingRequests=0 panelStopped=true")
    }

    private func makeFixture(lookupFailure: LyricsLookupError? = nil) -> MusicFixture {
        let value = MusicFixture(lookupFailure: lookupFailure); fixtures.append(value); return value
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
    private func skipExistingReads(_ value: MusicFixture) async {
        value.readCursor = await value.reader.calls().last?.id ?? value.readCursor
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
    private func ownViewImage(_ island: IslandPanelController, progress: Double = 1) throws -> (image: CGImage, width: Int, height: Int) {
        guard let view = island.panel.contentView, island.smokeProgress == progress,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(label: "missing own-view bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage,
              abs(CGFloat(bitmap.pixelsWide) - view.bounds.width * screen.backingScaleFactor) <= 2,
              abs(CGFloat(bitmap.pixelsHigh) - view.bounds.height * screen.backingScaleFactor) <= 2 else {
            throw Failure(label: "own-view bitmap has unexpected backing dimensions")
        }
        return (image, bitmap.pixelsWide, bitmap.pixelsHigh)
    }
    private func makeNotice(duration: NoticeDuration = .long, verifiedContinuity: Bool = false) throws -> RefreshNotice {
        let base = Date().addingTimeInterval(-5), reset = Date().addingTimeInterval(3600)
        func quota(_ used: Double, at date: Date) throws -> QuotaSnapshot {
            let identity = verifiedContinuity ? "\"accountId\":\"synthetic-music-account\"," : ""
            let json = "{\(identity)\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)}}}"
            return try QuotaParser.parse(Data(json.utf8), fetchedAt: date)
        }
        var tracker = QuotaUpdateTracker()
        let first = try quota(20, at: base); _ = tracker.record(first, at: base)
        let second = try quota(21, at: Date()), update = tracker.record(second, at: second.fetchedAt)
        guard let notice = RefreshNotice.make(result: update, snapshot: second, preferredBucketID: "codex",
            preferredWindowID: "codex:primary", duration: duration, receivedAt: second.fetchedAt), notice.isEligible else {
            throw Failure(label: "synthetic changed quota did not form eligible notice")
        }
        if verifiedContinuity {
            guard case let .decreased(points)? = notice.change, abs(points - 1) < 0.001 else {
                throw Failure(label: "synthetic verified account continuity did not produce the one-point OCR delta")
            }
        }
        return notice
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        let elapsed = CACurrentMediaTime() - startedAt
        stop()
        let valid = success && elapsed <= 100 && paintedChecks == 1 && passivePaintChecks == 5 && legacyLabelChecks == 6 && expandedChecks == 2
        print(valid ? "MUSIC_OK: checks=\(checks) elapsed=\(decimal(elapsed)) synthetic=true localViewPixels=true scanout=false"
                    : "MUSIC_FAILED: native synthetic music integration contract failed")
        completion(valid)
    }
    func stop() {
        watchdog?.invalidate(); watchdog = nil
        task?.cancel(); task = nil
        island?.stop()
        for panel in passivePanels { panel.stop() }
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
    init(lookupFailure: LyricsLookupError? = nil) {
        let reader = MusicFixtureGate<Bool, MusicReadResult>()
        let lookup = MusicFixtureGate<MusicLookupInput, LyricsLookupResult>()
        let importer = MusicFixtureGate<URL, LyricsDocument>()
        self.reader = reader; self.lookup = lookup; self.importer = importer
        controller = MusicLyricsController(synthetic: true, reader: MusicFixtureReader(gate: reader),
            lookup: { track, consent in
                let result = await lookup.invoke(MusicLookupInput(track: track, consent: consent))
                if let lookupFailure { throw lookupFailure }
                return result
            },
            importer: { url in await importer.invoke(url) })
    }
}

private enum MusicRasterOCR {
    /// Vision text recognition is on-device. A timeout resumes independently of
    /// the worker and cancels its request, leaving the main run loop responsive.
    static func recognize(_ image: CGImage, languages: [String] = ["zh-Hans", "en-US"]) async -> [String]? {
        await withCheckedContinuation { continuation in
            let gate = MusicOCRGate(continuation)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = languages
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
