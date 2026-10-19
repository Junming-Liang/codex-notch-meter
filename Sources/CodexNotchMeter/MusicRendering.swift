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
    private static let longTwoLine = "Silver lanterns drift across the quiet harbor"
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
    private var lastOCRLines: [MusicOCRLine] = []
    private var lastOCRImage: CGImage?
    private var nativeExpectations: [ObjectIdentifier: (progress: Double, after: TimeInterval)] = [:]

    init(screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.screen = screen; self.completion = completion
        super.init()
    }

    func start() {
        guard !started, !finished else { return }
        started = true; startedAt = CACurrentMediaTime(); initialKey = NSApp.keyWindow
        guard CommandLine.arguments.contains("--music-test") else { finish(false); return }
        let timer = Timer(timeInterval: 150, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                SmokeDiagnostics.mark("music bounded 150-second deadline exceeded")
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
                self.dumpSyntheticFailureState()
                if let failure = error as? Failure { SmokeDiagnostics.mark("music failed: \(failure.label)") }
                else { SmokeDiagnostics.mark("music cancelled or fixture operation failed") }
                self.finish(false)
            }
        }
    }

    private func run() async throws {
        try verifyOCRMatchingControls()
        try verifyArtworkDecoder()
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
        try require(primary.controller.line.isEmpty && primary.controller.nextLine.isEmpty && !primary.controller.isPlayingForPresentation, "pause removes the lyric instead of retaining the previous cue")
        print("MUSIC_TIMELINE_OK: forwardSeek=true backwardSeek=true pausedCleared=\(decimal(ProcessInfo.processInfo.systemUptime - pausedAt))")

        // Hold the next real 3-second paused read in flight. The production
        // freshness timer, rather than an injected stale notification, must clear.
        let heldForExpiry = try await read(primary)
        try require(!heldForExpiry.input && heldForExpiry.startedAt - pause.startedAt >= 2.95,
                    "paused polling uses its real three-second interval")
        try await until("five-second paused-source freshness expiry clears retained metadata", timeout: 5.5) {
            primary.controller.line.isEmpty && primary.controller.nextLine.isEmpty && primary.controller.trackTitle.isEmpty
                && primary.controller.statusText == "Music 播放信息已过期" && !primary.controller.isPlayingForPresentation
        }
        let expiredAge = ProcessInfo.processInfo.systemUptime - pausedAt
        try require(expiredAge >= LyricsTimeline().freshnessInterval && !primary.controller.canImport,
                    "expired playback cannot import or retain a lyric")
        print("MUSIC_STALE_OK: age=\(decimal(expiredAge)) freshness=5 lineEmpty=true titleEmpty=true")
        try await until("no-document source also expires its title") {
            noDocument.controller.line.isEmpty && noDocument.controller.nextLine.isEmpty && noDocument.controller.trackTitle.isEmpty
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
            primary.controller.line.isEmpty && primary.controller.nextLine.isEmpty && primary.controller.trackTitle.isEmpty && !primary.controller.canImport
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
            primary.controller.needsAuthorization && primary.controller.line.isEmpty && primary.controller.nextLine.isEmpty && primary.controller.trackTitle.isEmpty
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
        try require(paintedChecks == 1 && passivePaintChecks == 22 && legacyLabelChecks == 23 && expandedChecks == 2 && checks >= 100,
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
                value.controller.line.isEmpty && value.controller.nextLine.isEmpty && value.controller.trackTitle.isEmpty && !value.controller.canImport
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
        // Select lyrics through the real crossing recognizer before isolating
        // manual-details geometry from the passive ownership path below.
        let selectedAt = CACurrentMediaTime()
        try openLyrics(island)
        try await waitMusic(island, after: selectedAt)
        // Require a completed passive-to-idle transition before beginning this
        // distinct manual expansion. A repeated already-expanded request cannot
        // manufacture the fresh viewport acknowledgement required below.
        let suppressedAt = CACurrentMediaTime()
        island.setMusicPresentationAllowed(false)
        try await waitIdle(island, after: suppressedAt)
        try require(island.smokeExpansionOwner == .idle && !island.isInteracting,
                    "manual expansion starts from the measured suppressed idle owner")
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
        try require(!island.beginSmokeExpansion() && island.smokeNoticeTargetActive
            && island.smokeNoticeArmedAt == armed, "ordinary hover cannot consume the notice dwell")
        island.dismissRefreshNotice()
        let fullFrame = island.geometry.frame(progress: 1)
        island.smokePointer(at: CGPoint(x: fullFrame.midX, y: fullFrame.minY - 5), now: CACurrentMediaTime())
        try require(island.beginSmokeExpansion(), "explicit dismissal permits a fresh details hover")
        try await until("promoted expanded viewport settles") { self.nativeSettled(island, progress: 1, after: promotedAt) }
        try await dwell(0.15)
        try verifyExpanded(island)
        try require(!island.smokeNoticeTargetActive && !island.smokeNoticeVisible && island.smokeNoticeArmedAt == nil,
                    "explicit dismissal retires notice and expiry without losing expanded Quit")
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
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            island.panel.appearance = NSAppearance(named: appearance)
            try await until("long-lyric footer stays naturally measured in both appearances") {
                viewport.contains(quitFrame) && quitFrame.width > 20 && quitFrame.height >= 20
                    && island.verifyExpandedLayout(includePixels: false)
            }
            let footerUnchanged = abs(quitFrame.minY - baseline.minY) < 0.5 && abs(quitFrame.height - baseline.height) < 0.5
            let contained = viewport.contains(quitFrame) && hosting.fittingSize.height <= 590
            let compactQuit = island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting()
            let appearanceMatches = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance
                && island.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance
            print("MUSIC_LONG_LAYOUT_DIAGNOSTIC: appearance=\(appearance.rawValue) footerUnchanged=\(footerUnchanged) contained=\(contained) compactQuit=\(compactQuit) appearanceMatches=\(appearanceMatches) quitFrame=\(quitFrame) viewport=\(viewport)")
            try require(footerUnchanged && contained && compactQuit && appearanceMatches && !panel.isKeyWindow,
                        "long lyric and eight quotas keep both real footers contained and routed in both appearances")
        }
        print("MUSIC_LONG_LAYOUT_OK: view=DetailView quotaRows=8 longLyric=true footerUnchanged=true quitContained=true compactQuit=true appearances=aqua,darkAqua")
        panel.orderOut(nil); panel.close(); detailPanel = nil
        try await verifyMinimumFooters(fixture, model: model, many: many)
        model.setUpdateFixture(original)
    }

    private func verifyMinimumFooters(_ fixture: MusicFixture, model: MeterModel, many: QuotaSnapshot) async throws {
        guard let geometry = makeGeometry(contentHeight: 132), let first = many.buckets.first,
              let window = first.windows.first else { throw Failure(label: "missing minimum-height native footer fixture") }
        let one = QuotaSnapshot(buckets: [QuotaBucket(id: first.id, name: first.name, windows: [window])], fetchedAt: many.fetchedAt)
        var observations = 0
        for (rows, snapshot) in [(1, one), (8, many)] {
            let fresh = try await read(fixture); try await release(fixture, fresh, position: 1)
            model.setUpdateFixture(snapshot)
            let panel = IslandPanelController(model: model, geometry: geometry, startPolling: false,
                musicPresentationAllowed: false, hovered: {}, refresh: {}, settings: {}, quit: {})
            passivePanels.append(panel)
            let openedAt = CACurrentMediaTime()
            try require(panel.beginSmokeExpansion(), "open minimum-height real native lyric/details footer")
            try await until("minimum-height full native viewport and footer settle") {
                self.nativeSettled(panel, progress: 1, after: openedAt) && panel.verifyExpandedLayout(includePixels: false)
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                panel.panel.appearance = NSAppearance(named: appearance)
                let native = nativeSettled(panel, progress: 1, after: openedAt)
                let contained = panel.verifyExpandedLayout(includePixels: false)
                let routing = panel.verifySmokeClickRouting()
                let paint = panel.verifyExpandedLayout(includePixels: true)
                let appearanceMatches = panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance
                print("MUSIC_MINIMUM_FOOTER_DIAGNOSTIC: rows=\(rows) appearance=\(appearance.rawValue) native=\(native) contained=\(contained) routing=\(routing) paint=\(paint) appearanceMatches=\(appearanceMatches) contentHeight=\(geometry.contentHeight) lyricPresent=\(!fixture.controller.line.isEmpty) selected=\(panel.smokeLyricsSelected)")
                try require(native && contained && routing && paint && appearanceMatches && geometry.contentHeight == 132
                    && !fixture.controller.line.isEmpty && panel.smokeLyricsSelected && NSApp.keyWindow === initialKey,
                    "actual long-lyric footer at minimum height contains and routes Quit with \(rows) quota rows")
                observations += 1
            }
            panel.stop()
        }
        try require(observations == 4, "both minimum-height quota counts and native appearances were observed")
        print("MUSIC_MINIMUM_FOOTER_OK: contentHeight=132 quotaRows=1,8 appearances=aqua,darkAqua observations=4 longLyric=true quitContained=true clickRouting=true ownViewPixels=true")
    }

    private func verifyTrackRevisionAndLocalReplacement() async throws {
        let fixture = makeFixture()
        fixture.controller.start(); fixture.controller.setOnlineLookupEnabled(true); fixture.controller.setEnabled(true)
        let a1 = try await read(fixture); try await release(fixture, a1, position: 1)
        let oldA = try await lookup(fixture)
        guard let originalSelection = fixture.controller.importSelectionToken else { throw Failure(label: "missing A file-picker token") }
        let b = try await read(fixture); try await release(fixture, b, track: "HARBOR B", position: 1)
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
        try require(fixture.controller.line == Self.firstLine && fixture.controller.trackTitle == "HARBOR A",
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
            try require(value.controller.line.isEmpty && value.controller.nextLine.isEmpty && value.controller.trackTitle.isEmpty && !value.controller.canImport
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
            try require(value.controller.line.isEmpty && value.controller.nextLine.isEmpty && value.controller.trackTitle.isEmpty
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

    /// Exercise real current/next publications and native content-fit geometry.
    /// Every replacement waits for the exact imported document and real reader
    /// return. OCR observes only this original synthetic view, never the screen.
    private func verifyLyricPreview() async throws {
        let fixture = makeFixture()
        let model = MeterModel(demo: true, music: fixture.controller)
        let panel = try makePassivePanel(model)
        fixture.controller.start(); fixture.controller.setEnabled(true)
        let initial = try await read(fixture); try await release(fixture, initial, position: 1)
        let pairText = "[00:00]\(Self.firstLine)\n[00:30]\(Self.secondLine)\n[01:00]\(Self.localLine)"
        var changedAt = CACurrentMediaTime()
        try await importDocument(fixture, text: pairText)
        try await waitIdle(panel, after: 0)
        try require(!panel.smokeLyricsSelected, "fresh usable preview stays closed before an explicit crossing")
        try openLyrics(panel)
        try await waitMusic(panel, after: changedAt)
        let pairHeight = panel.panel.frame.height
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fresh = try await read(fixture); try await release(fixture, fresh, position: 1)
            try await verifyPreviewPixels(fixture, panel: panel, appearance: appearance,
                label: "current-next", current: Self.firstLine, next: Self.secondLine,
                absent: [Self.localLine], synchronized: true)
        }

        // The immediate next cue is explicitly blank. Never skip it to display
        // the later nonempty second line, even while the current text is equal.
        let beforeClearRevision = fixture.controller.presentationRevision
        changedAt = CACurrentMediaTime()
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)\n[00:30]\n[01:00]\(Self.secondLine)")
        try await waitMusic(panel, after: changedAt)
        let singleHeight = panel.panel.frame.height
        try require(panel.smokeLyricsSelected && fixture.controller.presentationRevision > beforeClearRevision
            && fixture.controller.nextLine.isEmpty && singleHeight < pairHeight,
            "clearing only next publishes a new revision and shrinks the actual native body")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fresh = try await read(fixture); try await release(fixture, fresh, position: 1)
            try await verifyPreviewPixels(fixture, panel: panel, appearance: appearance,
                label: "next-cleared", current: Self.firstLine, next: "",
                absent: [Self.secondLine, Self.localLine], synchronized: true)
        }
        let freshLong = try await read(fixture); try await release(fixture, freshLong, position: 1)
        changedAt = CACurrentMediaTime()
        try await importDocument(fixture, text: "[00:00]\(Self.longTwoLine)")
        try await waitMusic(panel, after: changedAt)
        let longHeight = panel.panel.frame.height
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fresh = try await read(fixture); try await release(fixture, fresh, position: 1)
            try await verifyPreviewPixels(fixture, panel: panel, appearance: appearance,
                label: "long-current", current: Self.longTwoLine, next: "",
                absent: [Self.firstLine, Self.secondLine, Self.localLine], synchronized: true, twoRows: true)
        }
        let compactWidth = panel.geometry.contourRect(progress: panel.smokeMusicTargetProgress).width
        let hoverWidth = panel.geometry.contourRect(progress: 1).width
        try require(abs(compactWidth - 360) < 0.001 && abs(hoverWidth - 400) < 0.001
            && longHeight > singleHeight && panel.geometry.compactContentWidth < compactWidth
            && panel.geometry.detailContentWidth < hoverWidth,
            "content-fit native single/next/two-line bodies share the 360 and 400 point contour endpoints")
        print("MUSIC_PREVIEW_PAINT_OK: cases=6 appearances=aqua,darkAqua currentNext=true nextCleared=true longCurrentRows=2 exactText=true leftAligned=true typeHierarchy=true nextGray=true localViewPixels=true scanout=false")
        print("MUSIC_PREVIEW_LAYOUT_OK: pairHeight=\(decimal(pairHeight)) singleHeight=\(decimal(singleHeight)) longHeight=\(decimal(longHeight)) compactWidth=\(decimal(compactWidth)) hoverWidth=\(decimal(hoverWidth)) safeDepth=\(decimal(panel.geometry.notch.height)) missingNextShrinks=true")

        let boundaryRead = try await read(fixture); try await release(fixture, boundaryRead, position: 1)
        changedAt = CACurrentMediaTime()
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)\n[00:04]\(Self.secondLine)\n[00:06]\n[00:30]\(Self.localLine)")
        try await waitMusic(panel, after: changedAt)
        try require(fixture.controller.nextLine == Self.secondLine, "boundary starts with a genuine immediate next cue")
        try await until("real line timer advances to the cue before a blank gap", timeout: 4) {
            fixture.controller.line == Self.secondLine && fixture.controller.nextLine.isEmpty
        }
        try await waitMusic(panel, after: changedAt)
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .aqua, label: "boundary",
            current: Self.secondLine, next: "", absent: [Self.firstLine, Self.localLine], synchronized: true)
        let backward = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, backward, position: 1)
        try await waitMusic(panel, after: changedAt)
        try require(fixture.controller.line == Self.firstLine && fixture.controller.nextLine == Self.secondLine,
                    "real backward seek restores both current and immediate next")
        let forward = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, forward, position: 35)
        try await waitMusic(panel, after: changedAt)
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .darkAqua, label: "forward-seek",
            current: Self.localLine, next: "", absent: [Self.firstLine, Self.secondLine], synchronized: true)
        let gap = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, gap, position: 8)
        try await waitIdle(panel, after: changedAt)
        try require(panel.smokeLyricsSelected, "temporary explicit gap retains the user-selected lyric mode")
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .aqua, label: "explicit-gap",
            current: "", next: "", absent: [Self.firstLine, Self.secondLine, Self.localLine], synchronized: false)
        let gapReturn = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, gapReturn, position: 35)
        try await waitMusic(panel, after: changedAt)
        try require(panel.smokeLyricsSelected && fixture.controller.line == Self.localLine,
                    "the next usable cue restores selected lyrics after a temporary gap without another crossing")
        let newTrack = try await read(fixture)
        try await release(fixture, newTrack, track: "HARBOR B", position: 1)
        try await waitIdle(panel, after: 0)
        try require(panel.smokeLyricsSelected, "track revision hides stale cues while retaining the explicit runtime mode")
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .darkAqua, label: "new-track",
            current: "", next: "", absent: [Self.firstLine, Self.secondLine, Self.localLine, "HARBOR A"], synchronized: false)
        try await importDocument(fixture, text: "[00:30]\(Self.firstLine)\n[00:50]\(Self.secondLine)", expectedCurrent: "")
        try await waitIdle(panel, after: 0)
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .aqua, label: "before-first",
            current: "", next: "", absent: [Self.firstLine, Self.secondLine], synchronized: false)

        fixture.controller.setOnlineLookupEnabled(true)
        fixture.controller.clearLocalLyrics()
        let instrumental = try await lookup(fixture)
        try require(fixture.controller.lookupState == .loading && !fixture.controller.isPlayingForPresentation,
                    "real pending lookup remains ineligible for automatic expansion")
        try await waitIdle(panel, after: 0)
        try require(await fixture.lookup.release(instrumental.id, .matched(.instrumental)), "return explicit instrumental source evidence")
        try await until("instrumental lookup returns and its exact document is applied") {
            let returned = await fixture.lookup.returnedIDs().contains(instrumental.id)
            return returned && fixture.controller.syntheticLyricsDocument == .instrumental
                && fixture.controller.lookupState == .matched && fixture.controller.statusText == "纯音乐"
        }
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .darkAqua, label: "instrumental",
            current: "", next: "", absent: [Self.firstLine, Self.secondLine, "纯音乐"], synchronized: false)

        let plainRead = try await read(fixture); try await release(fixture, plainRead, track: "HARBOR B", position: 1)
        changedAt = CACurrentMediaTime()
        try await importDocument(fixture, text: "\(Self.firstLine)\n\(Self.secondLine)")
        try require(panel.smokeLyricsSelected, "fresh plain lyrics inherit the retained explicit runtime mode")
        try await waitMusic(panel, after: changedAt)
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .aqua, label: "plain-unsynchronized",
            current: Self.firstLine, next: "", absent: [Self.secondLine], synchronized: false)
        try require(fixture.controller.statusText.contains("未同步") && contains(lastOCRLines.map(\.text), "未同步"),
                    "plain first line is explicitly unsynchronized in real pixels and never invents a next cue")

        let staleRead = try await read(fixture)
        let sourceAt = ProcessInfo.processInfo.systemUptime
        changedAt = CACurrentMediaTime()
        try await release(fixture, staleRead, track: "HARBOR B", position: 1, observedAt: sourceAt)
        try await importDocument(fixture, text: pairText)
        try await waitMusic(panel, after: changedAt)
        try require(fixture.controller.line == Self.firstLine && fixture.controller.nextLine == Self.secondLine,
                    "stale fixture starts with genuinely presented current and next cues")
        _ = try await read(fixture) // Keep this real ordinary read pending through expiry.
        try await until("real source freshness clears both visible preview cues", timeout: 5.5) {
            !fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty
                && fixture.controller.nextLine.isEmpty && fixture.controller.trackTitle.isEmpty
                && fixture.controller.statusText == "Music 播放信息已过期"
        }
        try await waitIdle(panel, after: changedAt)
        let staleAge = ProcessInfo.processInfo.systemUptime - sourceAt
        try await verifyPreviewPixels(fixture, panel: panel, appearance: .darkAqua, label: "stale-preview",
            current: "", next: "", absent: [Self.firstLine, Self.secondLine, "HARBOR B"], synchronized: false)
        try require(staleAge >= 5 && staleAge <= 7 && panel.smokeLyricsSelected,
                    "visible preview retirement follows real freshness while retaining the explicit runtime mode")
        print("MUSIC_PREVIEW_TRANSITIONS_OK: boundary=true backwardSeek=true forwardSeek=true gap=true gapReturnSelected=true newTrackModeRetained=true beforeFirst=true loading=true instrumental=true plainUnsynchronized=true stale=true ownViewOCR=8")
        print("MUSIC_PREVIEW_STALE_OK: age=\(decimal(staleAge)) previouslyPainted=true currentEmpty=true nextEmpty=true owner=idle")
        fixture.controller.stop(); panel.stop()
    }

    private func verifyPreviewPixels(_ fixture: MusicFixture, panel: IslandPanelController,
                                     appearance: NSAppearance.Name, label: String, current: String, next: String,
                                     absent: [String], synchronized: Bool, twoRows: Bool = false) async throws {
        panel.panel.appearance = NSAppearance(named: appearance)
        if current.isEmpty { try await waitIdle(panel, after: 0) }
        else { try await waitMusic(panel, after: 0) }
        let progress = current.isEmpty ? 0 : panel.smokeMusicTargetProgress
        let captured = (line: fixture.controller.line, next: fixture.controller.nextLine,
            synchronized: fixture.controller.isSynchronized, title: fixture.controller.trackTitle,
            revision: fixture.controller.presentationRevision, frame: panel.panel.frame,
            appearance: panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        let observations = try await compactOCR(panel, progress: progress)
        let currentMatches = captured.line == current && (current.isEmpty || contains(observations, current))
        let nextMatches = captured.next == next && (next.isEmpty || contains(observations, next))
        let forbiddenAbsent = absent.allSatisfy { !contains(observations, $0) }
        let appearanceMatches = captured.appearance == appearance
        let synchronizationMatches = captured.synchronized == synchronized
        let titleMatches = current.isEmpty ? !contains(observations, captured.title) : contains(observations, captured.title)
        let textContained = current.isEmpty || lastOCRLines.allSatisfy {
            let top = captured.frame.height * (1 - $0.bounds.maxY)
            let bottom = captured.frame.height * (1 - $0.bounds.minY)
            return top >= panel.geometry.notch.height + 4 && bottom <= captured.frame.height - 4
        }
        func normalized(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        let currentRows = lastOCRLines.filter {
            let text = normalized($0.text)
            return text.count >= 6 && normalized(current).contains(text)
        }
        let twoRowsMatch = !twoRows || (currentRows.count == 2
            && abs(currentRows[0].bounds.midY - currentRows[1].bounds.midY) > min(currentRows[0].bounds.height, currentRows[1].bounds.height) / 2)
        if !next.isEmpty {
            guard currentRows.count == 1,
                  let currentRow = currentRows.first,
                  let nextRow = lastOCRLines.first(where: { contains([$0.text], next) }),
                  let titleRow = lastOCRLines.first(where: { contains([$0.text], captured.title) }),
                  let image = lastOCRImage else { throw Failure(label: "missing exact current/next/title raster metrics") }
            let currentHeight = currentRow.bounds.height * captured.frame.height
            let nextHeight = nextRow.bounds.height * captured.frame.height
            let titleHeight = titleRow.bounds.height * captured.frame.height
            let currentLeft = currentRow.bounds.minX * captured.frame.width
            let nextLeft = nextRow.bounds.minX * captured.frame.width
            let titleLeft = titleRow.bounds.minX * captured.frame.width
            let currentLight = try glyphLuminance(image, bounds: currentRow.bounds)
            let nextLight = try glyphLuminance(image, bounds: nextRow.bounds)
            let titleLight = try glyphLuminance(image, bounds: titleRow.bounds)
            let sizeHierarchy = MusicPreviewLayout.currentFontSize == 18 && MusicPreviewLayout.nextFontSize == 12
                && currentHeight >= 12 && currentHeight <= 23 && nextHeight >= 7 && nextHeight <= 15
                && titleHeight >= 5 && titleHeight <= 12 && currentHeight > nextHeight * 1.20 && nextHeight > titleHeight
            let leadingAligned = abs(currentLeft - nextLeft) <= 4 && abs(currentLeft - titleLeft) <= 4
            let colorHierarchy = currentLight > 0.75 && nextLight >= 0.20 && nextLight < 0.65
                && currentLight > nextLight + 0.20 && titleLight > nextLight + 0.05
            print("MUSIC_PREVIEW_TYPE_DIAGNOSTIC: appearance=\(appearance.rawValue) currentHeight=\(decimal(currentHeight)) nextHeight=\(decimal(nextHeight)) titleHeight=\(decimal(titleHeight)) currentLeft=\(decimal(currentLeft)) nextLeft=\(decimal(nextLeft)) titleLeft=\(decimal(titleLeft)) currentLight=\(decimal(currentLight)) nextLight=\(decimal(nextLight)) titleLight=\(decimal(titleLight)) sizeHierarchy=\(sizeHierarchy) leadingAligned=\(leadingAligned) colorHierarchy=\(colorHierarchy)")
            try require(sizeHierarchy && leadingAligned && colorHierarchy,
                        "actual own-view glyph bounds and colors preserve dominant 18-point current, 12-point gray next and small title")
        }
        print("MUSIC_PREVIEW_DIAGNOSTIC: case=\(label) appearance=\(appearance.rawValue) currentMatches=\(currentMatches) nextMatches=\(nextMatches) forbiddenAbsent=\(forbiddenAbsent) appearanceMatches=\(appearanceMatches) synchronizationMatches=\(synchronizationMatches) titleMatches=\(titleMatches) textContained=\(textContained) currentRows=\(currentRows.count) twoRowsMatch=\(twoRowsMatch) revision=\(captured.revision) paintRevision=\(panel.paintReceipt?.frame.musicRevision ?? 0) frame=\(captured.frame)")
        try require(currentMatches && nextMatches && forbiddenAbsent && appearanceMatches
            && synchronizationMatches && titleMatches && textContained && twoRowsMatch,
            "\(label) \(appearance.rawValue) exact own-view current/next, absence, safe-area and row evidence")
    }

    private func glyphLuminance(_ image: CGImage, bounds: CGRect) throws -> Double {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let left = max(0, Int(floor(bounds.minX * CGFloat(image.width))))
        let right = min(image.width, Int(ceil(bounds.maxX * CGFloat(image.width))))
        let top = max(0, Int(floor((1 - bounds.maxY) * CGFloat(image.height))))
        let bottom = min(image.height, Int(ceil((1 - bounds.minY) * CGFloat(image.height))))
        var samples: [Double] = []
        for y in top..<bottom {
            for x in left..<right {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent >= 0.5 else { continue }
                let value = Double(color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722)
                if value > 0.05 { samples.append(value) }
            }
        }
        guard !samples.isEmpty else { throw Failure(label: "OCR glyph bounds contain no own-view painted text") }
        samples.sort()
        return samples[min(samples.count - 1, Int(Double(samples.count - 1) * 0.9))]
    }

    /// All samples use the real injected reader and production 1 s / 3 s polling.
    /// Notice holds are the public 6 s and 4 s choices, measured only after the
    /// existing natural Canvas/readiness gate. No synthetic clock drives motion.
    private func verifyAutomaticPresentation() async throws {
        island?.stop()
        try await verifyLyricPreview()
        try await verifyGestureNegatives()
        let fixture = makeFixture()
        let model = MeterModel(demo: true, music: fixture.controller)
        let panel = try makePassivePanel(model)
        fixture.controller.start(); fixture.controller.setEnabled(true)
        let initial = try await read(fixture)
        let observedAt = ProcessInfo.processInfo.systemUptime
        let artwork = try originalArtwork()
        try await release(fixture, initial, position: 1, observedAt: observedAt, artwork: artwork)
        try await waitIdle(panel, after: 0)
        let idleFrame = panel.panel.frame
        let idleContour = panel.geometry.contourRect(progress: 0)
        let idleFrames = passiveFrameSamples
        try require(!panel.smokeMusicGesture(openLyrics: true) && !panel.smokeLyricsSelected,
                    "complete left-to-right crossing without a usable cue stays silently closed")
        try await waitIdle(panel, after: 0)
        try require(!fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty
            && fixture.controller.nextLine.isEmpty && !fixture.controller.hasLocalLyrics
            && fixture.controller.statusText.contains("LRC"),
            "fresh playing without a usable document retains the measured idle outline")
        let statusPixels = try await compactOCR(panel, progress: 0)
        try verifyClosedArtwork(panel, expected: artwork, controller: fixture.controller)
        let titleAbsent = !contains(statusPixels, "HARBOR A")
        let importStatusAbsent = !contains(statusPixels, "LRC")
        let obsoleteLyricAbsent = !contains(statusPixels, Self.firstLine)
        print("MUSIC_AUTO_EMPTY_DIAGNOSTIC: titleAbsent=\(titleAbsent) importStatusAbsent=\(importStatusAbsent) obsoleteLyricAbsent=\(obsoleteLyricAbsent) owner=\(String(reflecting: panel.smokeExpansionOwner)) opacity=\(panel.paintReceipt?.frame.surfaceOpacity ?? -1)")
        try require(titleAbsent && importStatusAbsent && obsoleteLyricAbsent,
                    "no-document own-view pixels retain only the idle outline")
        print("MUSIC_GESTURE_EMPTY_OK: fullCrossing=true noLyrics=true selected=false owner=idle statusAbsent=true ownViewOCR=true passive=true")

        // Hold the ordinary read and observe the real five-second source expiry.
        // No lyric-less sample may create even a transient automatic expansion.
        let expiredRead = try await read(fixture)
        try await until("idle no-document playing source expires", timeout: 5.5) {
            !fixture.controller.isPlayingForPresentation && fixture.controller.trackTitle.isEmpty
                && fixture.controller.statusText == "Music 播放信息已过期"
        }
        let sourceAge = ProcessInfo.processInfo.systemUptime - observedAt
        try await waitIdle(panel, after: 0)
        try require(sourceAge >= 5 && fixture.controller.line.isEmpty && fixture.controller.nextLine.isEmpty
            && !fixture.controller.canImport && panel.panel.frame.height == idleFrame.height
            && panel.geometry.contourFrame.height == idleContour.height && passiveFrameSamples > idleFrames
            && !panel.smokeMusicAccessoriesVisible && fixture.controller.artwork == nil,
                    "natural no-document expiry clears accessories without expanding the raw contour or painting a lyric body")
        print("MUSIC_CLOSED_STALE_OK: age=\(decimal(sourceAge)) document=unavailable lyricBodyPainted=false accessoryCleared=true owner=idle")
        let recoveredAt = CACurrentMediaTime()
        try await release(fixture, expiredRead, position: 1, artwork: artwork)
        fixture.controller.setOnlineLookupEnabled(true)
        let matched = try await lookup(fixture)
        try await waitIdle(panel, after: 0)
        let matchedDocument = try document("[by:synthetic-matched-\(UUID().uuidString)]\n[00:00]\(Self.firstLine)")
        try require(await fixture.lookup.release(matched.id, .matched(matchedDocument)), "return exact synthetic matched lyric")
        try await until("matched request returns and exact usable lyric opens eligibility") {
            let returned = await fixture.lookup.returnedIDs().contains(matched.id)
            return returned && fixture.controller.syntheticLyricsDocument == matchedDocument
                && fixture.controller.lookupState == .matched && fixture.controller.line == Self.firstLine
                && fixture.controller.isPlayingForPresentation && !fixture.controller.hasLocalLyrics
        }
        try await waitIdle(panel, after: 0)
        let defaultPixels = try await compactOCR(panel, progress: 0)
        try require(!panel.smokeLyricsSelected && !contains(defaultPixels, Self.firstLine)
            && !contains(defaultPixels, "HARBOR A") && panel.panel.frame == panel.geometry.frame(progress: 0)
            && panel.panel.frame.height <= panel.geometry.notch.height + 4,
            "matched playing source remains in the true hardware-depth closed state with no lyric or title")
        try await verifyNaturalGestureOwnership(panel, model: model, fixture: fixture)
        let afterPointerChecks = try await read(fixture)
        try await release(fixture, afterPointerChecks, position: 1, artwork: artwork)
        try await enterDetails(panel)
        try require(!panel.smokeLyricsSelected, "ordinary hover shows details without enabling lyric mode")
        try await exitDetails(panel)
        try await waitIdle(panel, after: recoveredAt)
        try openLyrics(panel)
        try await waitMusic(panel, after: recoveredAt)
        print("MUSIC_GESTURE_MATCH_OK: requestReturned=true exactDocument=true defaultClosed=true hardwareDepth=true fullCrossing=true owner=music hoverSeparate=true")
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        // An identical visible line must still await this new import's exact
        // document receipt, rather than accepting the previous local state.
        try require(fixture.controller.line == Self.firstLine, "same-line import control starts with its expected cue already visible")
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        print("MUSIC_IMPORT_COMPLETION_OK: sameLine=true oldDocumentRejected=true requestReturned=true exactDocument=true expectedCue=true")
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
        let noticeFrame = panel.panel.frame
        let noticeFrames = passiveFrameSamples
        let noticePixels = try await compactOCR(panel)
        try require(contains(noticePixels, "80%") && contains(noticePixels, "79%")
            && !contains(noticePixels, Self.firstLine) && !contains(noticePixels, "HARBOR A"),
            "actual compact pixels replace Music with the 80 to 79 percent quota notice")
        try require(panel.showRefreshNotice(notice), "repeated identical notice is accepted without a new dwell")
        var playingUpdates = 0
        var lyricUpdates = 0
        var pointerSamples = 0
        let deadline = armed + notice.holdDuration + 2
        while panel.smokeNoticeTargetActive && CACurrentMediaTime() < deadline {
            let visibleFrame = panel.geometry.frame(progress: panel.smokeProgress)
            let visibleContour = panel.geometry.contourRect(progress: panel.smokeProgress)
            let bottom = visibleFrame.maxY - visibleContour.maxY
            panel.smokePointer(at: CGPoint(x: visibleFrame.midX,
                y: bottom + (pointerSamples.isMultiple(of: 2) ? 1 : -1)), now: CACurrentMediaTime())
            pointerSamples += 1
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
                    && passiveFrameSamples == noticeFrames && panel.panel.frame == noticeFrame
                    && panel.smokeExpansionOwner == .quotaNotice && !panel.smokeMusicTargetActive && panel.smokeLyricsSelected
                    && panel.panel.ignoresMouseEvents && !panel.isInteracting,
                    "repeated playing and lyric publications cannot reset native notice dwell or motion")
            }
            try await dwell(0.02)
        }
        let held = CACurrentMediaTime() - armed
        try require(!panel.smokeNoticeTargetActive && held >= notice.holdDuration && held <= notice.holdDuration + 1.5
            && playingUpdates >= 2 && lyricUpdates >= 2 && pointerSamples >= 20,
            "real long notice completes six fully-painted seconds despite Music and adjacent pointer samples")
        print("MUSIC_NOTICE_POINTER_DWELL_OK: seconds=6 held=\(held) pointerSamples=\(pointerSamples) musicUpdates=\(playingUpdates)")
        try await waitMusic(panel, after: armed + notice.holdDuration)
        for index in 0..<20 {
            let frame = panel.geometry.frame(progress: panel.smokeProgress)
            let contour = panel.geometry.contourRect(progress: panel.smokeProgress)
            panel.smokePointer(at: CGPoint(x: frame.midX,
                y: frame.maxY - contour.maxY + (index.isMultiple(of: 2) ? 1 : -1)), now: CACurrentMediaTime())
            try require(panel.smokeExpansionOwner == .music && !panel.isInteracting,
                "adjacent pointer after expiry cannot inherit hover and steal the restored music shell")
            try await dwell(0.02)
        }
        try require(ObjectIdentifier(panel.panel) == panelIdentity && panel.panel.frame == compactFrame
            && !panel.smokeNoticeVisible && fixture.controller.isPlayingForPresentation && panel.smokeLyricsSelected,
            "notice expiry returns directly to Music in the same compact native panel")
        panel.panel.appearance = NSAppearance(named: .darkAqua)
        try await dwell(0.15)
        let returnPixels = try await compactOCR(panel)
        print("MUSIC_RETURN_OCR_DIAGNOSTIC: lyricVisible=\(contains(returnPixels, fixture.controller.line)) lineNonempty=\(!fixture.controller.line.isEmpty) quotaAbsent=\(!contains(returnPixels, "79%")) titleVisible=\(contains(returnPixels, "HARBOR A")) darkAppearance=\(panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)")
        try require(contains(returnPixels, fixture.controller.line) && !fixture.controller.line.isEmpty
            && !contains(returnPixels, "79%") && contains(returnPixels, "HARBOR A")
            && panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            "own-view pixels prove Music to quota notice to Music content replacement")
        print("MUSIC_AUTO_PRIORITY_OK: hold=\(decimal(held)) expected=6 paintBeforeArm=true playingUpdates=\(playingUpdates) lyricUpdates=\(lyricUpdates) dwellUnchanged=true motionUnchanged=true samePanel=true")
        print("MUSIC_AUTO_PAINT_OK: sequence=music-notice-music lyricBefore=true quota80to79=true lyricAfter=true appearances=aqua,darkAqua width=\(Int(compactFrame.width * screen.backingScaleFactor)) height=\(Int(compactFrame.height * screen.backingScaleFactor)) scale=\(decimal(screen.backingScaleFactor)) localViewPixels=true scanout=false")

        let reverseAt = CACurrentMediaTime()
        try require(panel.smokeMusicGesture(openLyrics: false) && !panel.smokeLyricsSelected,
                    "complete right-to-left crossing closes the selected lyric mode")
        try await waitIdle(panel, after: reverseAt)
        let reversePixels = try await compactOCR(panel, progress: 0)
        try require(!contains(reversePixels, fixture.controller.line) && !contains(reversePixels, "HARBOR A")
            && fixture.controller.isPlayingForPresentation && !fixture.controller.line.isEmpty,
            "reverse-crossing own-view pixels remove lyrics while playback and the document remain valid")
        try await verifyClosedGestureNotice(fixture, panel: panel)
        try openLyrics(panel)
        try await waitMusic(panel, after: reverseAt)
        print("MUSIC_GESTURE_REVERSE_OK: fullCrossing=true selected=false ownViewLyricAbsent=true playbackPreserved=true reopened=true")

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
        try await until("real paused sample revokes passive Music") { !fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty && fixture.controller.nextLine.isEmpty }
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
        try require(panel.smokeLyricsSelected, "pause retains the explicit runtime lyric mode for fresh resume")
        try await waitMusic(panel, after: resumedAt)
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try await enterDetails(panel)
        let hoverPause = try await read(fixture)
        try await release(fixture, hoverPause, position: 1, state: .paused)
        try await until("paused hover keeps details ownership but removes Music") {
            !fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty && fixture.controller.nextLine.isEmpty
                && panel.smokeExpansionOwner == .details && panel.smokeProgress == 1
        }
        try await dwell(0.15)
        let hoverRaster = try ownViewImage(panel)
        guard let pausedPixels = await MusicRasterOCR.recognize(hoverRaster.image) else {
            throw Failure(label: "bounded paused-details OCR failed")
        }
        print("MUSIC_PAUSED_OCR_DIAGNOSTIC: observations=\(String(reflecting: pausedPixels)) lyricAbsent=\(!contains(pausedPixels, Self.firstLine)) titleAbsent=\(!contains(pausedPixels, "HARBOR A")) quotaVisible=\(contains(pausedPixels, "Codex")) layoutValid=\(panel.verifyExpandedLayout(includePixels: false))")
        passivePaintChecks += 1
        try verifyNoLegacyLabel(pausedPixels)
        try require(!contains(pausedPixels, Self.firstLine) && !contains(pausedPixels, "HARBOR A")
            && contains(pausedPixels, "Codex") && panel.verifyExpandedLayout(includePixels: false),
            "paused expanded details retain quota and footer while Music lyric and title disappear from pixels")
        try await exitDetails(panel)
        try await waitIdle(panel, after: resumedAt)
        let nextResumeAt = CACurrentMediaTime()
        let nextResume = try await read(fixture); try await release(fixture, nextResume, position: 1)
        try require(panel.smokeLyricsSelected, "hover pause retains selection without retaining stale content")
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
        print("MUSIC_LABEL_OK: nativeOCR=23 previewOCR=14 legacyWordAbsent=true")

        // A pending ordinary read lets a true paused sample arrive during a real
        // close/open reversal. Poll cadence is never shortened to manufacture it.
        let reversingRead = try await read(fixture)
        panel.setMusicPresentationAllowed(false)
        try await until("real compact closing motion begins") {
            panel.smokeMotionRunning && panel.smokeProgress > 0 && panel.smokeProgress < panel.smokeMusicTargetProgress
        }
        panel.setMusicPresentationAllowed(true)
        try require(panel.smokeTargetProgress == panel.smokeMusicTargetProgress && panel.smokeMotionRunning,
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
        try require(panel.smokeStopped && recreated.panel !== panel.panel && fixture.controller.isPlayingForPresentation
            && recreated.smokeLyricsSelected, "recreated island inherits the controller's explicit runtime mode without a new sample")
        print("MUSIC_GESTURE_RECREATE_OK: inheritedSelected=true oldPanelStopped=true noNewSample=true")
        try await verifyPassiveRetirement(fixture, panel: recreated)
        try await verifyReducedMotionPresentation()
    }

    private func verifyPassiveRetirement(_ fixture: MusicFixture, panel: IslandPanelController) async throws {
        var changedAt = CACurrentMediaTime()
        await skipExistingReads(fixture)
        fixture.controller.setActive(false)
        try await waitIdle(panel, after: changedAt)
        try require(!fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty && fixture.controller.nextLine.isEmpty, "sleep retires passive Music")
        fixture.controller.setActive(true)
        let wake = try await read(fixture)
        try require(!wake.input, "passive wake remains nonprompting")
        changedAt = CACurrentMediaTime(); try await release(fixture, wake, position: 1)
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try require(panel.smokeLyricsSelected, "fresh usable playback restores the existing runtime mode")
        try await waitMusic(panel, after: changedAt)
        await skipExistingReads(fixture)
        changedAt = CACurrentMediaTime(); fixture.controller.setEnabled(false)
        try await waitIdle(panel, after: changedAt)
        fixture.controller.setEnabled(true)
        let enabled = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, enabled, position: 1)
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try await waitIdle(panel, after: 0)
        try require(!panel.smokeLyricsSelected, "disabling and reenabling the feature resets the runtime mode to closed")
        try openLyrics(panel)
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
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try require(panel.smokeLyricsSelected, "fresh usable playback restores the existing runtime mode")
        try await waitMusic(panel, after: changedAt)
        let stoppedRead = try await read(fixture)
        changedAt = CACurrentMediaTime()
        try require(await fixture.reader.release(stoppedRead.id, snapshot(position: 1, state: .stopped)), "deliver stopped playback")
        try await waitIdle(panel, after: changedAt)
        try require(!fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty && fixture.controller.nextLine.isEmpty,
                    "stopped playback removes passive Music")
        fixture.controller.requestAuthorization()
        let again = try await read(fixture)
        changedAt = CACurrentMediaTime(); try await release(fixture, again, position: 1)
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try require(panel.smokeLyricsSelected, "fresh usable playback restores the existing runtime mode")
        try await waitMusic(panel, after: changedAt)
        changedAt = CACurrentMediaTime(); fixture.controller.stop()
        try await waitIdle(panel, after: changedAt)
        try require(!fixture.controller.isPlayingForPresentation && fixture.controller.line.isEmpty && fixture.controller.nextLine.isEmpty, "terminal stop removes passive Music")
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
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try await waitIdle(panel, after: 0)
        try require(!panel.smokeLyricsSelected, "new usable playback does not restore a retired lyric selection")
        try openLyrics(panel)
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

    private func verifyGestureNegatives() async throws {
        let fixture = makeFixture()
        let model = MeterModel(demo: true, music: fixture.controller)
        let panel = try makePassivePanel(model, reducedMotion: true)
        fixture.controller.start(); fixture.controller.setEnabled(true)
        let initial = try await read(fixture); try await release(fixture, initial, position: 1)
        try await importDocument(fixture, text: "[00:00]\(Self.firstLine)")
        try await waitIdle(panel, after: 0)
        let corridor = panel.smokeMusicGestureCorridor
        let outside = CGPoint(x: panel.geometry.screen.minX - 10, y: panel.geometry.screen.minY - 10)
        func point(_ fraction: CGFloat, _ y: CGFloat? = nil) -> CGPoint {
            CGPoint(x: corridor.minX + corridor.width * fraction, y: y ?? corridor.midY)
        }
        let cases: [(String, [CGPoint], Bool)] = [
            ("center", [point(0.5), point(0.7), point(0.98)], false),
            ("vertical", [point(0.02, corridor.minY + 1), point(0.02, corridor.midY), point(0.02, corridor.maxY + 5)], false),
            ("jitter", [point(0.02), point(0.03), point(0.02), point(0.03), point(0.02)], false),
            ("buttonDown", [point(0.02), point(0.25), point(0.52), point(0.75), point(0.98)], true)
        ]
        for (name, points, buttonDown) in cases {
            let now = ProcessInfo.processInfo.systemUptime
            panel.smokePointer(at: outside, now: now, buttonDown: buttonDown)
            for (index, value) in points.enumerated() {
                panel.smokePointer(at: value, now: now + Double(index + 1) * 0.035, buttonDown: buttonDown)
            }
            let unchanged = !panel.smokeLyricsSelected && panel.smokeMusicGestureCorridor == corridor
            print("MUSIC_GESTURE_NEGATIVE_DIAGNOSTIC: case=\(name) selected=\(panel.smokeLyricsSelected) corridorUnchanged=\(panel.smokeMusicGestureCorridor == corridor) buttonStateInjected=\(buttonDown) points=\(points.count) owner=\(String(reflecting: panel.smokeExpansionOwner))")
            try require(unchanged, "native \(name) pointer samples do not select lyrics")
            if name == "center" {
                // Enter at the exposed lower U, beneath the camera exclusion.
                // Keep one fixed center point while real uptime and run-loop
                // samples satisfy ordinary hover, without a forced expansion.
                let closedFrame = panel.geometry.frame(progress: 0)
                let closedContour = panel.geometry.contourRect(progress: 0)
                let center = CGPoint(x: closedFrame.minX + closedContour.midX,
                    y: closedFrame.maxY - closedContour.maxY + 1)
                let enteredAt = CACurrentMediaTime()
                panel.smokePointer(at: outside, now: ProcessInfo.processInfo.systemUptime)
                try await until("center entry with lyrics mode off naturally opens ordinary details") {
                    panel.smokePointer(at: center, now: ProcessInfo.processInfo.systemUptime)
                    return !panel.smokeLyricsSelected && panel.smokeExpansionOwner == .details
                        && self.nativeSettled(panel, progress: 1, after: enteredAt)
                        && self.naturalPaintMatches(panel, progress: 1, after: enteredAt)
                }
                let usableAtCapture = fixture.controller.isPlayingForPresentation && fixture.controller.line == Self.firstLine
                let selectedAtCapture = panel.smokeLyricsSelected
                let quitVisible = panel.verifyExpandedLayout(includePixels: false) && panel.verifySmokeClickRouting()
                let pixels = try await compactOCR(panel, progress: 1)
                let lyricAbsent = !contains(pixels, Self.firstLine)
                let titleAbsent = !contains(pixels, "HARBOR A")
                let quotaVisible = contains(pixels, "Codex")
                print("MUSIC_GESTURE_HOVER_OFF_DIAGNOSTIC: usableAtCapture=\(usableAtCapture) selectedAtCapture=\(selectedAtCapture) quitVisible=\(quitVisible) lyricAbsent=\(lyricAbsent) titleAbsent=\(titleAbsent) quotaVisible=\(quotaVisible) center=\(center) owner=\(String(reflecting: panel.smokeExpansionOwner))")
                try require(usableAtCapture && !selectedAtCapture && !panel.smokeLyricsSelected
                    && quitVisible && lyricAbsent && titleAbsent && quotaVisible,
                    "ordinary center hover retains quota and Quit without displaying usable but unselected lyrics")
                let exitedAt = CACurrentMediaTime()
                let outsidePanel = CGPoint(x: panel.geometry.screen.minX - 10, y: panel.geometry.screen.minY - 10)
                try await until("ordinary mode-off hover exit naturally returns to painted idle") {
                    panel.smokePointer(at: outsidePanel, now: ProcessInfo.processInfo.systemUptime)
                    return !panel.smokeLyricsSelected && panel.smokeExpansionOwner == .idle
                        && self.nativeSettled(panel, progress: 0, after: exitedAt)
                        && self.naturalPaintMatches(panel, progress: 0, after: exitedAt)
                }
                try await waitIdle(panel, after: exitedAt)
                print("MUSIC_GESTURE_HOVER_OFF_OK: centerEntry=true selected=false owner=details quitVisible=true lyricAbsentOCR=true titleAbsentOCR=true quotaVisibleOCR=true returnedIdle=true naturalPaint=true sampledPointer=true")
            }
            panel.collapse()
            // A rejected path may already be idle, so no new paint is promised.
            // Still require the exact settled viewport and current natural paint.
            try await waitIdle(panel, after: 0)
        }

        // Keep the continuation already pending before starting a crossing, so
        // each source change occurs inside the recognizer's real time budget.
        let track = try await read(fixture)
        var now = ProcessInfo.processInfo.systemUptime
        panel.smokePointer(at: outside, now: now)
        panel.smokePointer(at: point(0.02), now: now + 0.01)
        panel.smokePointer(at: point(0.25), now: now + 0.035)
        try await release(fixture, track, track: "HARBOR B", position: 1)
        try await importDocument(fixture, text: "[00:00]\(Self.secondLine)")
        panel.smokePointer(at: point(0.52), now: now + 0.08)
        panel.smokePointer(at: point(0.75), now: now + 0.115)
        panel.smokePointer(at: point(0.98), now: now + 0.15)
        try require(!panel.smokeLyricsSelected && fixture.controller.isPlayingForPresentation
            && fixture.controller.trackTitle == "HARBOR B", "new usable track rejects completion of an old partial crossing")
        panel.collapse(); try await waitIdle(panel, after: 0)
        let pause = try await read(fixture)
        now = ProcessInfo.processInfo.systemUptime
        panel.smokePointer(at: outside, now: now)
        panel.smokePointer(at: point(0.02), now: now + 0.01)
        panel.smokePointer(at: point(0.25), now: now + 0.035)
        try await release(fixture, pause, track: "HARBOR B", position: 1, state: .paused)
        panel.smokePointer(at: point(0.52), now: now + 0.08)
        panel.smokePointer(at: point(0.75), now: now + 0.115)
        panel.smokePointer(at: point(0.98), now: now + 0.15)
        try require(!panel.smokeLyricsSelected && !fixture.controller.isPlayingForPresentation,
                    "paused playback cancels the pending partial crossing without enabling lyrics")
        panel.collapse(); try await waitIdle(panel, after: 0)
        let resume = try await read(fixture); try await release(fixture, resume, track: "HARBOR B", position: 1)
        try await waitIdle(panel, after: 0)
        try require(!panel.smokeLyricsSelected, "fresh playback cannot complete an interrupted prior crossing")
        try openLyrics(panel); try await waitMusic(panel, after: 0)
        print("MUSIC_GESTURE_NEGATIVE_OK: center=true vertical=true jitter=true buttonDown=true trackReset=true pauseReset=true freshCrossingWorks=true realRecognizer=true sampledButtonState=true")
        fixture.controller.stop(); panel.stop()
    }

    private func verifyArtworkDecoder() throws {
        // Original 16×16 red/cyan PNG and original hostile-format fixtures. These
        // bytes are constructed offline; ImageIO receives no paths or URLs.
        guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAHUlEQVR4nGP8z4AdMP7HLsOEQz1OMKphVMPQ0QAAKJQDHnKJQdMAAAAASUVORK5CYII="),
              let wide = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAEAEAAAABCAIAAAA+gZcVAAAAJElEQVR4nO3BAQ0AAAwCoNs/9M3hBuQPAAAAAAAAAAAAAAAYUDXVAQHgUxkJAAAAAElFTkSuQmCC"),
              let animated = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAAQAAAAEAAAAAAAAAAAAAEACgAAY0bPJQAAAB1JREFUeJxj/M+AHTD+xy7DhEM9TjCqYVTD0NEAACiUAx5yiUHTAAAAGmZjVEwAAAABAAAAEAAAABAAAAAAAAAAAAABAAoAAPg1JfEAAAAcZmRBVAAAAAJ4nGNk+M9AEmAiTfmohlENQ0kDAD8vAR9V84UDAAAAAElFTkSuQmCC"),
              let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAQABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi69nrxivZ6OHP+Xvy/UPGf/mB/wC4n/uM/9k="),
              let decoded = MusicArtworkDecoder.decode(png),
              let decodedJPEG = MusicArtworkDecoder.decode(jpeg) else { throw Failure(label: "original bounded PNG did not decode") }
        for artwork in [decoded, decodedJPEG] {
            try require((1...64).contains(artwork.pixelWidth) && (1...64).contains(artwork.pixelHeight)
                && artwork.bytesPerRow == artwork.pixelWidth * 4
                && artwork.rgbaBytes.count == artwork.pixelWidth * artwork.pixelHeight * 4,
                "native original PNG/JPEG decoder returns only bounded exact RGBA thumbnail bytes")
        }
        let rejects: [(String, Data)] = [("empty", Data()), ("malformed", Data("not an image".utf8)),
            ("truncated", Data(png.prefix(12))), ("oversized", Data(repeating: 0, count: MusicArtworkDecodingPolicy.maximumEncodedBytes + 1)),
            ("wide", wide), ("animated", animated)]
        for (name, bytes) in rejects {
            let rejected = MusicArtworkDecoder.decode(bytes) == nil
            print("MUSIC_ARTWORK_DECODER_DIAGNOSTIC: case=\(name) bytes=\(bytes.count) rejected=\(rejected)")
            try require(rejected, "native artwork decoder rejects \(name) original in-memory bytes")
        }
        print("MUSIC_ARTWORK_DECODER_OK: originalPNG=true originalJPEG=true exactRGBA=true rejects=6 noFiles=true noNetwork=true")
    }

    private func originalArtwork() throws -> MusicArtwork {
        // Original asymmetric 16×16 PNG: red/cyan above green/yellow. Feed the
        // production decoder, then carry its exact bytes through the snapshot
        // and real view so channel swaps and orientation mistakes stay visible.
        guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAALUlEQVR4nGN8ZuTGgA1YNE3DKs6EVRQPGNVADGDUuBSAVWLfm8vUsWFUAzEAAMjGBpQP2Y6oAAAAAElFTkSuQmCC"),
              let artwork = MusicArtworkDecoder.decode(png),
              artwork.pixelWidth == 16, artwork.pixelHeight == 16,
              artwork.bytesPerRow == 64, artwork.rgbaBytes.count == 1024 else {
            throw Failure(label: "original asymmetric in-memory PNG did not decode into exact 16×16 RGBA")
        }
        return artwork
    }

    /// Replay sparse fast mouse samples through the production controller, then
    /// continue beside/down into the appeared shell rather than teleporting away.
    private func verifyNaturalGestureOwnership(_ panel: IslandPanelController, model: MeterModel, fixture: MusicFixture) async throws {
        let corridor = panel.smokeMusicGestureCorridor
        var observedPaints: Set<UInt64> = []
        for opening in [true, false] {
            let fresh = try await read(fixture)
            try await release(fixture, fresh, position: 1)
            let started = CACurrentMediaTime()
            var savedFrames = 0
            for fraction in [CGFloat(-0.1), 0.5, 1.1] {
                let x = opening ? fraction : 1 - fraction
                panel.smokePointer(at: CGPoint(x: corridor.minX + corridor.width * x, y: corridor.midY),
                    now: ProcessInfo.processInfo.systemUptime)
                try await dwell(1.0 / 30)
            }
            try require(panel.smokeLyricsSelected == opening, "sparse 30Hz real-time crossing selects the requested mode")
            let adjacent = CGPoint(x: opening ? corridor.maxX + 5 : corridor.minX - 5, y: corridor.minY - 6)
            try require(panel.geometry.hoverContains(adjacent, progress: 1),
                        "regression pointer remains inside the full shell after leaving the gesture band")
            for _ in 0..<36 {
                panel.smokePointer(at: adjacent, now: ProcessInfo.processInfo.systemUptime)
                try require(!panel.isInteracting && panel.smokeExpansionOwner == (opening ? .music : .idle)
                    && panel.smokeTargetProgress == (opening ? panel.smokeMusicTargetProgress : 0),
                    "adjacent/downward gesture exit never transiently promotes details or retargets expansion")
                if let paint = panel.paintReceipt, paint.observed >= started,
                   paint.frame.progress > 0, paint.frame.progress < panel.smokeMusicTargetProgress {
                    let expected = IslandContour(rect: panel.geometry.contourRect(progress: paint.frame.progress),
                        progress: paint.frame.progress, cornerAdjustment: panel.geometry.shapeCalibration.corner,
                        referenceDepth: panel.geometry.notch.height)
                    try require(paint.frame.contour == expected && paint.frame.railOpacity == 1
                        && paint.bodyBounds == contourPath(expected, inset: 0, closed: true).boundingRect
                        && paint.railBounds == contourPath(expected, inset: 2, closed: false).boundingRect,
                        "moving music shell and perimeter rail are submitted from one exact geometry frame")
                    observedPaints.insert(paint.sequence)
                    let ratio = paint.frame.progress / panel.smokeMusicTargetProgress
                    let threshold = opening ? [0.2, 0.5, 0.8] : [0.8, 0.5, 0.2]
                    if savedFrames < 3, paint.frame.progress == panel.smokeProgress,
                       (opening ? ratio >= threshold[savedFrames] : ratio <= threshold[savedFrames]) {
                        let raster = try ownViewImage(panel, progress: panel.smokeProgress)
                        let directory = URL(fileURLWithPath: "dist/contour-rendering/music", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        guard let png = NSBitmapImageRep(cgImage: raster.image).representation(using: .png, properties: [:]) else {
                            throw Failure(label: "cannot encode natural motion own-view frame")
                        }
                        savedFrames += 1
                        let direction = opening ? "open" : "close"
                        try png.write(to: directory.appendingPathComponent("perimeter-motion-\(direction)-\(savedFrames).png"), options: .atomic)
                    }
                }
                try await dwell(0.012)
            }
            try require(savedFrames == 3, "three natural in-flight own-view frames were retained for each gesture direction")
            if opening {
                try await waitMusic(panel, after: started)
                try await verifyMusicPerimeterPixels(panel, model: model, state: "compact")
                try await enterDetails(panel)
                try await verifyMusicPerimeterPixels(panel, model: model, state: "details")
                try await exitDetails(panel)
                try await waitMusic(panel, after: started)
                let g = panel.geometry
                guard let clipped = makeGeometry(contentHeight: g.contentHeight, shapeCalibration: .init(depth: -6)) else {
                    throw Failure(label: "negative-depth native fixture geometry is valid")
                }
                try require(!clipped.canShowMusicAccessories, "negative-depth native fixture has no safe accessory wings")
                let noWings = IslandPanelController(model: model, geometry: clipped, startPolling: false,
                    reducedMotionOverride: true, hovered: {}, refresh: {}, settings: {}, quit: {})
                passivePanels.append(noWings)
                try require(noWings.beginSmokeExpansion(), "wing-ineligible music can still open details")
                try await until("wing-ineligible full music details paint") {
                    self.nativeSettled(noWings, progress: 1, after: 0) && self.naturalPaintMatches(noWings, progress: 1, after: 0)
                }
                try await verifyMusicPerimeterPixels(noWings, model: model, state: "details-no-wings")
                noWings.stop()
                let freshForClose = try await read(fixture)
                try await release(fixture, freshForClose, position: 1)
                guard let tallGeometry = makeGeometry(contentHeight: 340) else { throw Failure(label: "missing tall music geometry") }
                let tall = IslandPanelController(model: model, geometry: tallGeometry, startPolling: false,
                    reducedMotionOverride: false, hovered: {}, refresh: {}, settings: {}, quit: {})
                passivePanels.append(tall)
                try await waitMusic(tall, after: 0)
                let closeStarted = CACurrentMediaTime()
                tall.setMusicPresentationAllowed(false)
                try await waitIdle(tall, after: closeStarted)
                try require(tall.closeReceipt?.outcome == .ready,
                            "tall-card short lyric waits for both geometry channels before its unchanged close-paint deadline")
                tall.stop()
            } else { try await waitIdle(panel, after: started) }
        }
        try require(observedPaints.count >= 6, "both natural gesture transitions produced multiple actual paint frames")
        print("MUSIC_PERIMETER_OK: skins=5 states=compact,details,details-no-wings coloredOutside=true usedBlack=true innerBlack=true ownViewPixels=true scanout=false")
        print("MUSIC_NATURAL_POINTER_OK: sparse30Hz=true adjacentExit=true downwardExit=true noDetailsRetarget=true coupledCloseReady=true movingPaints=\(observedPaints.count) sharedContour=true scanout=false")
    }

    private func verifyMusicPerimeterPixels(_ panel: IslandPanelController, model: MeterModel, state: String) async throws {
        let original = model.theme
        defer { model.theme = original }
        let directory = URL(fileURLWithPath: "dist/contour-rendering/music", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in MeterTheme.allCases {
            model.theme = theme
            try await dwell(0.025)
            let raster = try ownViewImage(panel, progress: panel.smokeProgress)
            let bitmap = NSBitmapImageRep(cgImage: raster.image)
            guard let paint = panel.paintReceipt else { throw Failure(label: "music perimeter has no paint receipt") }
            let rect = paint.frame.contour.rect, side = rect.minX + paint.frame.contour.shoulder
            let y = rect.midY
            func color(_ x: CGFloat) -> NSColor? {
                bitmap.colorAt(x: Int((x * screen.backingScaleFactor).rounded(.down)),
                    y: Int((y * screen.backingScaleFactor).rounded(.down)))?.usingColorSpace(.deviceRGB)
            }
            let remainingSide = color(side + 2)
            let usedSide = color(rect.maxX - paint.frame.contour.shoulder - 2)
            let body = color(side + 8)
            let colored = remainingSide.map { max($0.redComponent, max($0.greenComponent, $0.blueComponent)) > 0.15 && $0.alphaComponent > 0.9 } ?? false
            let blackUsed = usedSide.map { max($0.redComponent, max($0.greenComponent, $0.blueComponent)) < 0.03 && $0.alphaComponent > 0.9 } ?? false
            let blackBody = body.map { max($0.redComponent, max($0.greenComponent, $0.blueComponent)) < 0.03 && $0.alphaComponent > 0.9 } ?? false
            try require(colored && blackUsed && blackBody && paint.frame.railOpacity == 1,
                        "\(theme.rawValue) paints a colored outer remaining edge, pure-black used edge and black inner body")
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(label: "cannot encode perimeter fixture") }
            try png.write(to: directory.appendingPathComponent("perimeter-\(state)-\(theme.rawValue).png"), options: .atomic)
        }
    }

    private func verifyClosedArtwork(_ panel: IslandPanelController, expected: MusicArtwork,
                                     controller: MusicLyricsController) throws {
        guard let image = lastOCRImage else { throw Failure(label: "missing closed own-view image") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scale = screen.backingScaleFactor
        let rects = panel.geometry.musicAccessoryRects(progress: 0)
        let top = max(0, (rects.left.height - 20) / 2)
        func color(at point: CGPoint) -> NSColor? {
            bitmap.colorAt(x: Int((point.x * scale).rounded(.down)), y: Int((point.y * scale).rounded(.down)))?.usingColorSpace(.deviceRGB)
        }
        let red = color(at: CGPoint(x: rects.left.minX + 12, y: top + 5))
        let cyan = color(at: CGPoint(x: rects.left.minX + 22, y: top + 5))
        let green = color(at: CGPoint(x: rects.left.minX + 12, y: top + 15))
        let yellow = color(at: CGPoint(x: rects.left.minX + 22, y: top + 15))
        let topLeftRed = red.map { $0.redComponent > 0.65 && $0.greenComponent < 0.35 && $0.blueComponent < 0.5 } == true
        let topRightCyan = cyan.map { $0.redComponent < 0.3 && $0.greenComponent > 0.5 && $0.blueComponent > 0.65 } == true
        let bottomLeftGreen = green.map { $0.redComponent < 0.35 && $0.greenComponent > 0.65 && $0.blueComponent < 0.5 } == true
        let bottomRightYellow = yellow.map { $0.redComponent > 0.65 && $0.greenComponent > 0.55 && $0.blueComponent < 0.3 } == true
        let artworkPixels = topLeftRed && topRightCyan && bottomLeftGreen && bottomRightYellow
        let indicator = CGRect(x: rects.right.maxX - 27, y: max(0, (rects.right.height - 20) / 2), width: 20, height: 20)
        var brightPixels = 0
        for y in Int(indicator.minY)..<Int(indicator.maxY) {
            for x in Int(indicator.minX)..<Int(indicator.maxX) {
                if let value = color(at: CGPoint(x: CGFloat(x), y: CGFloat(y))), min(value.redComponent, min(value.greenComponent, value.blueComponent)) > 0.4 {
                    brightPixels += 1
                }
            }
        }
        let rawContour = panel.geometry.contourFrame
        let rawUnchanged = abs(rawContour.width - panel.geometry.calibratedNotch.width - 6) < 0.001
            && abs(rawContour.height - panel.geometry.calibratedNotch.height - 3) < 0.001
        let depthMatches = panel.geometry.musicAccessoryFrame.height == panel.geometry.notch.height
            && panel.panel.frame.height <= panel.geometry.notch.height + 4
        print("MUSIC_CLOSED_ACCESSORIES_DIAGNOSTIC: sourceMatches=\(controller.artwork == expected) freshPlaying=\(controller.isFreshPlaying) accessoriesVisible=\(panel.smokeMusicAccessoriesVisible) artworkPixels=\(artworkPixels) topLeftRed=\(topLeftRed) topRightCyan=\(topRightCyan) bottomLeftGreen=\(bottomLeftGreen) bottomRightYellow=\(bottomRightYellow) brightIndicatorPixels=\(brightPixels) rawUnchanged=\(rawUnchanged) depthMatches=\(depthMatches) left=\(rects.left) right=\(rects.right)")
        try require(controller.artwork == expected && controller.isFreshPlaying && panel.smokeMusicAccessoriesVisible
            && artworkPixels && brightPixels >= 8 && rawUnchanged && depthMatches,
            "closed own-view pixels prove four source-defined decoded PNG quadrants, a playing glyph and unchanged hardware-depth contour")
        let directory = URL(fileURLWithPath: "dist/contour-rendering/music", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(label: "cannot encode closed artwork fixture") }
        try png.write(to: directory.appendingPathComponent("perimeter-closed-artwork.png"), options: .atomic)
        print("MUSIC_CLOSED_ACCESSORIES_OK: originalRGBA=true decoder-to-display=true artworkPixels=true quadrants=4 playingGlyph=true hardwareDepth=true rawContourUnchanged=true")
    }

    private func openLyrics(_ panel: IslandPanelController) throws {
        let before = panel.smokeLyricsSelected
        let accepted = panel.smokeMusicGesture(openLyrics: true)
        print("MUSIC_GESTURE_OPEN_DIAGNOSTIC: previouslySelected=\(before) accepted=\(accepted) selected=\(panel.smokeLyricsSelected) corridor=\(panel.smokeMusicGestureCorridor) owner=\(String(reflecting: panel.smokeExpansionOwner)) target=\(panel.smokeTargetProgress)")
        try require(accepted && panel.smokeLyricsSelected && !panel.isInteracting
            && panel.smokeExpansionOwner == .music && panel.smokeTargetProgress == panel.smokeMusicTargetProgress,
                    "a full no-button fixed-corridor left-to-right crossing selects passive lyric ownership after exit")
    }

    private func verifyClosedGestureNotice(_ fixture: MusicFixture, panel: IslandPanelController) async throws {
        let fresh = try await read(fixture); try await release(fixture, fresh, position: 1)
        let corridor = panel.smokeMusicGestureCorridor
        let fixedPoint = CGPoint(x: panel.geometry.screen.minX - 10, y: panel.geometry.screen.minY - 10)
        panel.smokePointer(at: fixedPoint, now: ProcessInfo.processInfo.systemUptime)
        try require(!panel.smokeLyricsSelected, "closed-mode notice fixture starts with an actual explicit reverse crossing")
        let notice = try makeNotice(duration: .short)
        try require(panel.showRefreshNotice(notice), "closed mode still accepts normal quota priority")
        try await waitNotice(panel, notice: notice)
        guard let armed = panel.smokeNoticeArmedAt else { throw Failure(label: "closed-mode notice never armed") }
        panel.smokePointer(at: fixedPoint, now: ProcessInfo.processInfo.systemUptime)
        let afterResizeCorridor = panel.smokeMusicGestureCorridor
        try require(afterResizeCorridor == corridor && !panel.smokeLyricsSelected
            && panel.smokeExpansionOwner == .quotaNotice,
            "native notice resizing with an unchanged outside pointer cannot create a directional crossing")
        let refresh = try await read(fixture); try await release(fixture, refresh, position: 1)
        try await until("closed-mode quota notice completes its original hold", timeout: 3) { !panel.smokeNoticeTargetActive }
        let hold = CACurrentMediaTime() - armed
        try await waitIdle(panel, after: armed + notice.holdDuration)
        try require(hold >= 2 && hold <= 3.5 && !panel.smokeLyricsSelected && fixture.controller.isPlayingForPresentation,
                    "quota notice returns to the still-selected closed mode despite usable playing lyrics")
        print("MUSIC_GESTURE_CLOSED_NOTICE_OK: hold=\(decimal(hold)) expected=2 owner=idle selected=false fixedCorridor=true stationaryPointer=true noResizeGesture=true")

        let changedAt = CACurrentMediaTime()
        try openLyrics(panel)
        try await until("rapid crossing fixture enters genuine native opening motion") {
            panel.smokeMotionRunning && panel.smokeProgress > 0 && panel.smokeProgress < panel.smokeMusicTargetProgress
        }
        try require(panel.smokeMusicGesture(openLyrics: false) && !panel.smokeLyricsSelected
            && panel.smokeTargetProgress == 0, "opposite full crossing reverses an in-flight lyric opening")
        try openLyrics(panel)
        try require(panel.smokeProgress.isFinite && panel.smokeVelocity.isFinite
            && panel.smokeTargetProgress == panel.smokeMusicTargetProgress,
            "rapid complete opposite directions retain a finite single-spring target")
        try await waitMusic(panel, after: changedAt)
        let closedAt = CACurrentMediaTime()
        try require(panel.smokeMusicGesture(openLyrics: false), "close after three rapid complete directions")
        try await waitIdle(panel, after: closedAt)
        print("MUSIC_GESTURE_RAPID_OK: sequence=open-close-open inFlightReversal=true finite=true finalClose=true")
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
            self.nativeSettled(panel, progress: panel.smokeMusicTargetProgress, after: after)
                && panel.smokeExpansionOwner == .music && panel.smokeMusicTargetActive && panel.smokeMusicVisible && panel.smokeLyricsSelected
                && !panel.smokeNoticeTargetActive && !panel.isInteracting && panel.panel.ignoresMouseEvents
                && self.naturalPaintMatches(panel, progress: panel.smokeMusicTargetProgress, after: after)
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
        try require(panel.paintReceipt?.frame.surfaceOpacity == (panel.smokeMusicAccessoriesVisible ? 1 : 0),
                    "idle paints exactly the closed music shell when accessories are visible, otherwise no expanded body")
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
            && receipt.frame.musicRevision == panel.smokeMusicPresentationRevision
            && abs(receipt.frame.surfaceOpacity - max(receipt.frame.accessoryProgress, panel.geometry.surfaceOpacity(progress: progress))) < 0.000001
    }
    private func compactOCR(_ panel: IslandPanelController, progress requestedProgress: Double? = nil, languages: [String] = ["zh-Hans", "en-US"]) async throws -> [String] {
        let progress = requestedProgress ?? (panel.smokeExpansionOwner == .music ? panel.smokeMusicTargetProgress : panel.geometry.updateProgress)
        // Readiness is checked before caching. A cache render proves content but
        // cannot manufacture natural-run-loop or physical-scanout readiness.
        try require(nativeSettled(panel, progress: progress, after: 0)
            && naturalPaintMatches(panel, progress: progress, after: 0),
            "compact own-view capture follows independently observed native readiness")
        let captureRevision = panel.smokeMusicPresentationRevision
        let captureAppearance = panel.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
        let raster = try ownViewImage(panel, progress: progress)
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
        guard let lines = await MusicRasterOCR.recognizeLines(raster.image, languages: languages) else {
            throw Failure(label: "bounded compact Music OCR failed")
        }
        lastOCRLines = lines; lastOCRImage = raster.image
        let observations = lines.map(\.text)
        let diagnostic: [String: Any] = ["fixture": "original-synthetic-only", "image": filename,
            "width": raster.width, "height": raster.height, "progress": progress,
            "scale": screen.backingScaleFactor, "observations": observations,
            "musicRevision": captureRevision,
            "textBounds": lines.map { line -> [String: Any] in
                ["text": line.text, "x": line.bounds.minX, "y": line.bounds.minY, "width": line.bounds.width, "height": line.bounds.height]
            },
            "appearance": captureAppearance]
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
                        && abs(opacity - max(paint.frame.accessoryProgress, panel.geometry.surfaceOpacity(progress: paint.frame.progress))) < 0.000001
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
        // An intentional fresh hover follows an actual exit from the full shell.
        let frame = panel.geometry.frame(progress: 1)
        panel.smokePointer(at: CGPoint(x: frame.maxX + 8, y: frame.midY), now: ProcessInfo.processInfo.systemUptime)
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
        let statusPanels = try values.map { try makePassivePanel(MeterModel(demo: true, music: $0.controller)) }
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
        for panel in statusPanels { try await waitIdle(panel, after: 0) }
        let statusFrames = passiveFrameSamples
        for _ in 0..<3 {
            for value in values {
                let request = try await read(value); try await release(value, request, position: 1)
            }
            try await dwell(0.04)
            for (index, value) in values.enumerated() {
                let lookupCount = await value.lookup.calls().count
                try require(value.controller.lookupState == states[index] && value.controller.statusText == statuses[index]
                    && !value.controller.isPlayingForPresentation && value.controller.line.isEmpty && value.controller.nextLine.isEmpty
                    && lookupCount == 1,
                    "same-track real polls preserve \(labels[index]) and do not repeat lookup")
                try await waitIdle(statusPanels[index], after: 0)
                try require(passiveFrameSamples == statusFrames && !statusPanels[index].smokeMusicVisible,
                            "\(labels[index]) and ordinary polls never create an automatic native lyric body")
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
            !transient.controller.isPlayingForPresentation && transient.controller.lookupState == .serviceUnavailable
                && transient.controller.statusText == statuses[0]
        }
        try require(await transient.lookup.calls().count == 1, "Music source interruption cannot bypass service cooldown")
        print("MUSIC_LOOKUP_RECOVERY_OK: source=timedOut freshSameTrack=true state=serviceUnavailable lookupCalls=1 cooldownPreserved=true")
        let observed = CACurrentMediaTime() - began
        try require(observed >= 3 && observed < 60, "service cooldown observation spans three real polls without waiting or skipping sixty seconds")
        for value in values { value.controller.stop() }
        for panel in statusPanels { panel.stop() }
        print("MUSIC_LOOKUP_IDLE_OK: states=serviceUnavailable,noMatch,unavailable,identityMismatch nativePanels=4 owner=idle motionFrames=0")
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
    private func snapshot(track: String = "HARBOR A", position: TimeInterval,
                          state: MusicPlaybackState = .playing, observedAt: TimeInterval? = nil,
                          artwork: MusicArtwork? = nil) -> MusicReadResult {
        guard let identity = MusicTrackIdentity(title: track, artist: "Original Fixture Ensemble", album: "Native Test Harbor", duration: 120),
              let value = MusicPlaybackSnapshot(track: identity, state: state, position: position,
                observedAt: observedAt ?? ProcessInfo.processInfo.systemUptime, artwork: artwork) else { return .unavailable(.invalidResponse) }
        return .snapshot(value)
    }
    private func release(_ value: MusicFixture, _ request: MusicFixtureCall<Bool>, track: String = "HARBOR A",
                         position: TimeInterval, state: MusicPlaybackState = .playing, observedAt: TimeInterval? = nil,
                         artwork: MusicArtwork? = nil) async throws {
        let result = snapshot(track: track, position: position, state: state, observedAt: observedAt, artwork: artwork)
        guard case .snapshot(let expected) = result else { throw Failure(label: "invalid synthetic read fixture") }
        try require(await value.reader.release(request.id, result),
                    "release actual pending synthetic Music request")
        do {
            try await until("exact synthetic read reaches controller") {
                let returned = await value.reader.returnedIDs().contains(request.id)
                return returned && value.controller.syntheticPlaybackSnapshot == expected
                    && value.controller.trackTitle == track && value.controller.canImport
            }
        } catch {
            let returned = await value.reader.returnedIDs().contains(request.id)
            print("MUSIC_READ_DIAGNOSTIC: request=\(request.id) returned=\(returned) expected=\(String(reflecting: expected)) actual=\(String(reflecting: value.controller.syntheticPlaybackSnapshot)) status=\(String(reflecting: value.controller.statusText))")
            throw error
        }
    }
    private func beginImport(_ controller: MusicLyricsController, path: String) throws {
        guard let token = controller.importSelectionToken else { throw Failure(label: "no fresh track for synthetic file selection") }
        controller.importLyrics(from: URL(fileURLWithPath: path), for: token)
    }
    private func importDocument(_ value: MusicFixture, text: String, expectedCurrent: String? = nil) async throws {
        // The parser retains this original metadata, while rendering ignores it.
        // It identifies application of this operation even if its visible cue is
        // identical to the previous document. No file is opened by this fixture.
        let operation = UUID().uuidString
        let result = try document("[by:fixture-operation-\(operation)]\n\(text)")
        let expectedLine: String
        if let expectedCurrent { expectedLine = expectedCurrent }
        else {
            switch result.content {
            case .synchronized(let cues): expectedLine = cues.first?.text ?? ""
            case .plain(let lines): expectedLine = lines.first ?? ""
            default: throw Failure(label: "import helper requires an explicit expected current cue")
            }
        }
        let samePriorLine = value.controller.line == expectedLine
        try beginImport(value.controller, path: "/synthetic-only.lrc")
        let request = try await imported(value)
        try require(value.controller.syntheticLyricsDocument != result,
                    "previous local document cannot satisfy the new import operation")
        try require(await value.importer.release(request.id, result), "complete injected in-memory import")
        do {
            try await until("exact local import and expected cue reach controller") {
                let returned = await value.importer.returnedIDs().contains(request.id)
                return returned && value.controller.syntheticLyricsDocument == result
                    && value.controller.hasLocalLyrics && value.controller.sourceLabel == "本地歌词"
                    && value.controller.line == expectedLine
            }
        } catch {
            let returned = await value.importer.returnedIDs().contains(request.id)
            print("MUSIC_IMPORT_DIAGNOSTIC: request=\(request.id) operation=\(operation) returned=\(returned) documentMatches=\(value.controller.syntheticLyricsDocument == result) samePriorLine=\(samePriorLine) expectedLine=\(String(reflecting: expectedLine)) actualLine=\(String(reflecting: value.controller.line)) status=\(String(reflecting: value.controller.statusText)) playback=\(String(reflecting: value.controller.syntheticPlaybackSnapshot))")
            throw error
        }
        print("MUSIC_IMPORT_RECEIPT: request=\(request.id) operation=\(operation) returned=true documentMatches=true expectedLine=true samePriorLine=\(samePriorLine)")
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
        // Vision can split or join glyph groups without changing their letters.
        // Normalize only case and Unicode whitespace, never spelling/numbers.
        func normalized(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
        let needle = normalized(expected)
        return !needle.isEmpty && normalized(observations.joined(separator: " ")).contains(needle)
    }
    private func verifyOCRMatchingControls() throws {
        let cases: [([String], String, Bool)] = [
            (["「 HARBORA"], "HARBOR A", true),
            (["HARBOR", "A"], "HARBOR A", true),
            (["harbor\u{00A0}a"], "HARBOR A", true),
            (["H A R B O R\tA"], "HARBOR A", true),
            (["HARBOR B"], "HARBOR A", false),
            (["HARBOR"], "HARBOR A", false),
            ([], "HARBOR A", false),
            (["HARBOR A"], "", false),
            (["HARBOR A"], " \n\t", false),
            (["Amber windows", "welcome the rain"], Self.localLine, true),
            ([Self.firstLine], Self.localLine, false),
            (["80 % + 79 %"], "79%", true),
            (["80% + 78%"], "79%", false),
            (["80% + 79"], "79%", false),
        ]
        for (index, value) in cases.enumerated() {
            try require(contains(value.0, value.1) == value.2, "exact-character OCR normalization control \(index)")
        }
        print("MUSIC_OCR_CONTROLS_OK: cases=14 whitespaceOnly=true wrongIdentityRejected=true wrongCueRejected=true wrongQuotaRejected=true emptyRejected=true")
    }
    private func dumpSyntheticFailureState() {
        // Only original in-memory fixtures enter this harness. These read-only
        // operands make later failures diagnosable before orderly retirement.
        for (index, value) in fixtures.enumerated() where value.controller.synthetic {
            let controller = value.controller
            print("MUSIC_FAILURE_SOURCE: fixture=\(index) enabled=\(controller.enabled) playing=\(controller.isPlayingForPresentation) title=\(String(reflecting: controller.trackTitle)) line=\(String(reflecting: controller.line)) next=\(String(reflecting: controller.nextLine)) synchronized=\(controller.isSynchronized) status=\(String(reflecting: controller.statusText)) local=\(controller.hasLocalLyrics) readCursor=\(value.readCursor) importCursor=\(value.importCursor) snapshot=\(String(reflecting: controller.syntheticPlaybackSnapshot))")
        }
        if let island { dumpPanelFailure(island, label: "primary") }
        for (index, panel) in passivePanels.enumerated() where panel !== island {
            dumpPanelFailure(panel, label: "passive-\(index)")
        }
    }
    private func dumpPanelFailure(_ panel: IslandPanelController, label: String) {
        let probe = panel.motionProbe
        print("MUSIC_FAILURE_PANEL: panel=\(label) owner=\(String(reflecting: panel.smokeExpansionOwner)) lyricsSelected=\(panel.smokeLyricsSelected) gestureCorridor=\(panel.smokeMusicGestureCorridor) progress=\(panel.smokeProgress) target=\(panel.smokeTargetProgress) motion=\(panel.smokeMotionRunning) interacting=\(panel.isInteracting) musicTarget=\(panel.smokeMusicTargetActive) musicVisible=\(panel.smokeMusicVisible) noticeTarget=\(panel.smokeNoticeTargetActive) noticeVisible=\(panel.smokeNoticeVisible) armed=\(String(reflecting: panel.smokeNoticeArmedAt)) probe=\(String(reflecting: probe))")
        guard let wanted = nativeExpectations[ObjectIdentifier(panel)] else { return }
        let frame = panel.geometry.frame(progress: wanted.progress)
        let bounds = CGRect(origin: .zero, size: frame.size)
        print("MUSIC_FAILURE_VIEWPORT: panel=\(label) expectedProgress=\(wanted.progress) requiredAfter=\(wanted.after) renderedAt=\(probe.renderedAt) expectedFrame=\(frame) visible=\(probe.visible) nonKey=\(probe.nonKey) keyUnchanged=\(NSApp.keyWindow === initialKey) placementValid=\(panel.placementIsValid) stopped=\(!probe.running) requestedMatches=\(probe.requestedProgress == wanted.progress) renderedMatches=\(probe.renderedProgress == wanted.progress) fresh=\(probe.renderedAt >= wanted.after) frameMatches=\(probe.frame == frame) viewportMatches=\(probe.viewport == frame.size) contentBoundsMatch=\(probe.contentBounds == bounds) presentationBoundsMatch=\(probe.layerPresentation == bounds) topAttached=\(abs(probe.frame.maxY - screen.frame.maxY) < 0.001) paint=\(String(reflecting: panel.paintReceipt))")
    }
    private func makeGeometry(contentHeight: CGFloat = 260, shapeCalibration: ContourCalibration = .init()) -> IslandGeometry? {
        let frame = screen.frame, width: CGFloat = 220, inset: CGFloat = 32
        let left = frame.midX - width / 2, right = frame.midX + width / 2
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: left - frame.minX, height: inset),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - inset, width: frame.maxX - right, height: inset)) else { return nil }
        return IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor,
            shapeCalibration: shapeCalibration, contentHeight: contentHeight)
    }
    private func nativeSettled(_ island: IslandPanelController, progress: Double, after: TimeInterval) -> Bool {
        nativeExpectations[ObjectIdentifier(island)] = (progress, after)
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
        let valid = success && elapsed <= 150 && paintedChecks == 1 && passivePaintChecks == 22 && legacyLabelChecks == 23 && expandedChecks == 2
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

private struct MusicOCRLine: Sendable {
    let text: String
    let bounds: CGRect
}

private enum MusicRasterOCR {
    /// Vision text recognition is on-device. A timeout resumes independently of
    /// the worker and cancels its request, leaving the main run loop responsive.
    static func recognize(_ image: CGImage, languages: [String] = ["zh-Hans", "en-US"]) async -> [String]? {
        await recognizeLines(image, languages: languages)?.map(\.text)
    }
    static func recognizeLines(_ image: CGImage, languages: [String] = ["zh-Hans", "en-US"]) async -> [MusicOCRLine]? {
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
                    gate.finish(request.results?.compactMap { observation in
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        return MusicOCRLine(text: text, bounds: observation.boundingBox)
                    })
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
    private var continuation: CheckedContinuation<[MusicOCRLine]?, Never>?
    init(_ continuation: CheckedContinuation<[MusicOCRLine]?, Never>) { self.continuation = continuation }
    func finish(_ result: [MusicOCRLine]?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: result)
    }
}
#endif
