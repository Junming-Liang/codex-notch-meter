#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Bounded native integration using production polling and ordinary pointer dwell.
/// No forced display, bitmap capture, Music IPC, files, network or defaults writes.
@MainActor
final class OrdinaryMotionRenderHarness: NSObject {
    private struct Failure: Error { let label: String }
    private let screen: NSScreen
    private let completion: (Bool) -> Void
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private var panels: [IslandPanelController] = []
    private var controllers: [MusicLyricsController] = []
    private var readers: [OrdinaryMotionReader] = []
    private var finished = false
    private var began: TimeInterval = 0
    private var traces: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private var callbacks: [[String: Any]] = []
    private var handoffs: [[String: Any]] = []
    private var lastHandoff: UInt64 = 0
    private var noticeRecords: [[String: Any]] = []
    private var gapRecords: [[String: Any]] = []
    private var overflow = false
    private var caseName = ""
    private weak var initialKey: NSWindow?

    init(screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.screen = screen; self.completion = completion; super.init()
    }
    func start() {
        guard !finished, task == nil, CommandLine.arguments.contains("--music-test"),
            CommandLine.arguments.contains("--ordinary-motion-test"), CommandLine.arguments.contains("--motion-test") else { finish(false); return }
        began = CACurrentMediaTime(); initialKey = NSApp.keyWindow
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(false) }
        }
        watchdog = timer; RunLoop.main.add(timer, forMode: .common)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
                self.finish(true)
            } catch {
                print("ORDINARY_MOTION_ERROR: \(error)")
                self.finish(false)
            }
        }
    }
    private func require(_ value: Bool, _ label: String) throws {
        if !value { throw Failure(label: caseName + ": " + label) }
    }
    private func dwell(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try Task.checkCancellation()
    }
    private func until(_ label: String, timeout: Double = 3,
                       _ condition: @escaping @MainActor () -> Bool) async throws {
        let end = CACurrentMediaTime() + timeout
        while !finished && CACurrentMediaTime() < end {
            if condition() { return }
            try await dwell(0.005)
        }
        throw Failure(label: caseName + ": " + label)
    }
    private func geometry(height: CGFloat = 260, shift: CGFloat = 0) throws -> IslandGeometry {
        let frame = screen.frame, inset: CGFloat = 32
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: frame.width / 2 - 110 + shift, height: inset),
            auxiliaryRight: CGRect(x: frame.midX + 110 + shift, y: frame.maxY - inset, width: frame.width / 2 - 110 - shift, height: inset)) else {
            throw Failure(label: "synthetic notch unavailable")
        }
        return IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor, contentHeight: height)
    }
    private func make(_ name: String, reduced: Bool = false, enabled: Bool = false, fallback: Bool = false, fractional: Bool = false) throws -> (IslandPanelController, MusicLyricsController, OrdinaryMotionReader) {
        caseName = name; events = []; callbacks = []; handoffs = []; lastHandoff = 0; noticeRecords = []; gapRecords = []
        let reader = OrdinaryMotionReader()
        let music = MusicLyricsController(synthetic: true, reader: reader)
        if enabled { music.setEnabled(true) }
        let model = MeterModel(demo: true, music: music)
        let panel = IslandPanelController(model: model, geometry: try geometry(shift: fractional ? 0.25 / screen.backingScaleFactor : 0), startPolling: false,
            reducedMotionOverride: reduced, motionProfile: fallback ? .timerFallback : .adaptive, motionSample: { [weak self] sample in
                guard let self else { return }
                if self.callbacks.count >= 1000 { self.overflow = true; return }
                guard let current = self.panels.last else { self.overflow = true; return }
                self.captureHandoff(current)
                self.callbacks.append(["observed": sample.observed, "scheduled": sample.scheduled,
                    "progress": sample.progress, "velocity": sample.velocity, "frame": self.rect(sample.frame), "source": sample.source,
                    "profile": current.smokeWidthProfile, "widthSample": self.width(current.smokeWidthSample),
                    "bridgeElapsed": current.smokeWidthBridgeElapsed ?? -1,
                    "bridgeTarget": current.smokeWidthBridgeTarget.map(self.width) ?? [],
                    "revision": current.smokeRenderCommits.last?.revision ?? 0,
                    "accessory": current.geometry.musicAccessoryProgress,
                    "noticeID": current.smokeNoticeID?.uuidString ?? "",
                    "musicRevision": current.smokeMusicPresentationRevision,
                    "renderedAt": current.motionProbe.renderedAt])
            }, hovered: {}, refresh: {}, settings: {}, quit: {})
        panels.append(panel); controllers.append(music); readers.append(reader)
        music.start()
        return (panel, music, reader)
    }
    private func event(_ name: String, _ p: IslandPanelController) {
        guard events.count < 64 else { overflow = true; return }
        captureHandoff(p)
        let s = p.smokeWidthSample
        events.append(["name": name, "time": CACurrentMediaTime(), "profile": p.smokeWidthProfile,
            "progress": p.smokeProgress, "velocity": p.smokeVelocity, "owner": String(describing: p.smokeExpansionOwner),
            "target": p.smokeTargetProgress, "width": s.width, "center": s.center,
            "widthVelocity": s.widthVelocity, "centerVelocity": s.centerVelocity])
    }
    private func width(_ sample: IslandWidthSample) -> [Double] {
        [sample.width, sample.center, sample.widthVelocity, sample.centerVelocity]
    }
    private func captureHandoff(_ p: IslandPanelController) {
        guard let receipt = p.smokeWidthHandoffReceipt, receipt.sequence > lastHandoff else { return }
        lastHandoff = receipt.sequence
        if handoffs.count >= 32 { overflow = true; return }
        handoffs.append(["sequence": receipt.sequence, "eventTime": receipt.eventTime,
            "integratedTime": receipt.integratedTime, "before": width(receipt.before), "after": width(receipt.after),
            "target": width(receipt.target), "oldProfile": receipt.oldProfile, "owner": String(describing: receipt.owner)])
    }
    private func pointer(_ inside: Bool, _ p: IslandPanelController) {
        p.smokePointer(inside: inside, now: CACurrentMediaTime())
    }
    private func open(_ p: IslandPanelController, settled: Bool = true) async throws {
        pointer(true, p); try await dwell(0.14); pointer(true, p)
        try require(p.smokeTargetExpanded, "ordinary hover dwell opens details")
        event("open", p)
        if settled { try await settle(p, target: 1) }
    }
    private func close(_ p: IslandPanelController, partial: Bool = false) async throws {
        pointer(false, p); try await dwell(0.24); pointer(false, p)
        try require(!p.smokeTargetExpanded, "ordinary exit dwell relinquishes details")
        event("close", p)
        if partial {
            try await until("closing has genuine intermediate progress and velocity") {
                p.smokeProgress > 0.03 && p.smokeProgress < min(0.85, p.geometry.updateProgress * 0.75)
                    && p.smokeVelocity < -0.1 && p.smokeWidthSample.widthVelocity < -1
            }
            event("closing-intermediate", p)
        }
    }
    private func settle(_ p: IslandPanelController, target: Double) async throws {
        try await until("exact endpoint has a natural native paint", timeout: 4) {
            guard let paint = p.paintReceipt else { return false }
            return p.smokeProgress == target && !p.smokeMotionRunning && !p.closePresentationPending
                && paint.frame.progress == target && paint.frame.viewport == p.panel.frame.size
                && paint.nativeFrame == p.panel.frame && paint.actualViewport == p.panel.frame.size
        }
        if target == 0, let receipt = p.closeReceipt {
            try require(receipt.outcome == .ready && receipt.renderedAt.map { $0 >= receipt.requestedAt } == true
                && receipt.paintedAt.map { $0 >= receipt.requestedAt } == true,
                "closed endpoint requires fresh actual render and paint acknowledgement, never timeout")
        }
        event("settled", p)
    }
    private func pending(_ r: OrdinaryMotionReader) async throws {
        let end = CACurrentMediaTime() + 3.8
        while CACurrentMediaTime() < end {
            if await r.hasPending() { return }
            try await dwell(0.005)
        }
        throw Failure(label: "actual production poll did not request synthetic read")
    }
    private func playback(_ state: MusicPlaybackState, _ r: OrdinaryMotionReader,
                          _ m: MusicLyricsController, _ p: IslandPanelController) async throws {
        try await pending(r)
        let before = await r.returnedCount()
        try require(await r.release(state), "release one genuine pending provider call")
        let end = CACurrentMediaTime() + 1
        while CACurrentMediaTime() < end {
            if await r.returnedCount() > before, m.isFreshPlaying == (state == .playing) {
                // Production Combine observer runs on the next main-queue turn.
                try await dwell(0.005); event(state == .playing ? "playing" : "paused", p); return
            }
            try await dwell(0.005)
        }
        throw Failure(label: "released provider result was not applied")
    }
    private func notice() throws -> RefreshNotice {
        let firstDate = Date().addingTimeInterval(-5), reset = Date().addingTimeInterval(3600)
        func snapshot(_ used: Int, _ date: Date) throws -> QuotaSnapshot {
            let json = "{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)}}}"
            return try QuotaParser.parse(Data(json.utf8), fetchedAt: date)
        }
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(try snapshot(20, firstDate), at: firstDate)
        let next = try snapshot(21, Date()), result = tracker.record(next, at: next.fetchedAt)
        guard let notice = RefreshNotice.make(result: result, snapshot: next, preferredBucketID: "codex",
            preferredWindowID: "codex:primary", duration: .short, receivedAt: next.fetchedAt) else {
            throw Failure(label: "eligible synthetic notice unavailable")
        }
        return notice
    }
    private func showNotice(_ p: IslandPanelController, label: String) throws {
        let value = try notice(), requested = CACurrentMediaTime()
        try require(p.showRefreshNotice(value), label)
        captureHandoff(p)
        noticeRecords.append(["id": value.id.uuidString, "requested": requested, "hold": value.holdDuration,
                              "kind": "requested"])
    }
    private func naturalExpiry(_ p: IslandPanelController) async throws {
        guard let request = noticeRecords.last, let id = request["id"] as? String,
            let requested = request["requested"] as? Double, let hold = request["hold"] as? Double else {
            throw Failure(label: "missing notice request identity")
        }
        try await until("exact replacement gets its own natural settled paint and readable timer", timeout: 4) {
            p.smokeNoticeID?.uuidString == id && p.smokeNoticeArmedAt != nil && p.smokeNoticePaintReadyAt != nil
        }
        guard let armed = p.smokeNoticeArmedAt, let painted = p.smokeNoticePaintReadyAt else {
            throw Failure(label: "missing readable notice receipts")
        }
        try require(painted >= requested && armed >= painted, "notice hold begins only after its own paint")
        try await until("notice naturally expires after complete configured readable hold", timeout: hold + 1) {
            !p.smokeNoticeTargetActive
        }
        let expired = CACurrentMediaTime()
        try require(expired >= armed + hold && p.smokeNoticeID?.uuidString == id,
                    "natural expiry belongs to exact replacement and preserves full readable duration")
        noticeRecords.append(["kind": "expired", "id": id, "requested": requested, "hold": hold,
                              "painted": painted, "armed": armed, "expired": expired])
    }
    private func rightEdge(_ p: IslandPanelController) throws -> (CGPoint, CGPoint) {
        let progress = p.smokeHoverSnapshotProgress, g = p.geometry
        let frame = g.frame(progress: progress), contour = g.contourRect(progress: progress)
        let y = frame.maxY - contour.midY
        var low = frame.midX, high = frame.maxX + 4
        try require(g.hoverContains(CGPoint(x: low, y: y), progress: progress), "edge search starts inside actual contour")
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if g.hoverContains(CGPoint(x: middle, y: y), progress: progress) { low = middle } else { high = middle }
        }
        return (CGPoint(x: low - 0.05, y: y), CGPoint(x: high + 0.05, y: y))
    }
    /// Real, tiny adjacent edge input; the 4ms main-thread load only lets wall
    /// time advance between dispatch frames. No frame/progress/receipt is forged.
    private func verifyRetargetGap(_ p: IslandPanelController) throws {
        try require(p.geometry.widthPresentation != nil && p.smokeWidthProfile == "ordinary-handoff",
                    "gap exercise starts from a genuinely published bridge")
        let (inside, outside) = try rightEdge(p)
        let outsideAt = CACurrentMediaTime()
        p.smokePointer(at: outside, now: outsideAt)
        Thread.sleep(forTimeInterval: 0.004)
        let reentryAt = CACurrentMediaTime()
        p.smokePointer(at: inside, now: reentryAt)
        let published = p.smokeHoverSnapshotProgress, integrated = p.smokeProgress
        let expected = p.geometry.hoverContains(inside, progress: published)
        let incorrect = p.geometry.hoverContains(inside, progress: integrated)
        let actual = p.smokeCurrentHoverContains(inside)
        try require(published != integrated && expected && !incorrect && actual && p.smokeTargetExpanded,
                    "retarget gap uses the published bridge contour instead of mismatched integrated progress")
        // Feed the same adjacent inside point through updatePointer again while
        // the retarget's unpublished progress gap is still present.
        p.smokePointer(at: inside, now: CACurrentMediaTime())
        try require(p.smokeTargetExpanded, "adjacent bridge reentry remains owned by details")
        gapRecords.append(["outside": [Double(outside.x), Double(outside.y)], "inside": [Double(inside.x), Double(inside.y)],
            "outsideAt": outsideAt, "reentryAt": reentryAt, "published": published, "integrated": integrated,
            "expected": expected, "mismatched": incorrect, "actual": actual, "updatePointerCalls": 3])
        event("adjacent-gap-reentry", p)
    }
    private func run() async throws {
        do {
            let (p, m, r) = try make("ordinary-reentry")
            try await open(p); try await close(p, partial: true)
            pointer(true, p); event("reentry", p)
            try require(p.smokeTargetExpanded && p.smokeWidthProfile == "ordinary-v100", "reentry retains ordinary width")
            try await settle(p, target: 1); try await close(p); try await settle(p, target: 0)
            try await collect(p, m, r)
        }
        do {
            let (p, m, r) = try make("quota-takeover-replacement-expiry")
            try await open(p); try await close(p, partial: true)
            try showNotice(p, label: "quota takeover accepted"); event("quota-takeover", p)
            try require(p.smokeWidthProfile == "ordinary-handoff", "quota starts width bridge")
            try await dwell(0.035)
            try showNotice(p, label: "quota replacement accepted"); event("quota-replacement", p)
            try await naturalExpiry(p)
            event("quota-expired", p); try await settle(p, target: 0)
            try await collect(p, m, r)
        }
        do {
            let (p, m, r) = try make("playback-during-opening", enabled: true)
            try await pending(r)
            try await open(p, settled: false)
            try await until("ordinary opening intermediate") { p.smokeProgress > 0.15 && p.smokeProgress < 0.85 }
            try await playback(.playing, r, m, p)
            try require(p.smokeProgress < 1 && p.smokeWidthProfile == "ordinary-v100", "playback preserves in-flight ordinary opening")
            try await settle(p, target: 1)
            try require(p.smokeWidthProfile == "shared-v103", "full endpoint safely releases ordinary latch")
            try await playback(.paused, r, m, p)
            try await close(p); try await settle(p, target: 0)
            try await collect(p, m, r)
        }
        do {
            let (p, m, r) = try make("playback-close-owner-redirect-pause", enabled: true)
            try await pending(r)
            try await open(p); try await close(p, partial: true)
            try await playback(.playing, r, m, p)
            try require(p.smokeWidthProfile == "ordinary-handoff", "closing playback starts width bridge")
            try showNotice(p, label: "quota redirects active playback handoff"); event("owner-redirect", p)
            try await playback(.paused, r, m, p)
            try require(p.smokeExpansionOwner == .quotaNotice, "pause preserves quota priority")
            try await naturalExpiry(p)
            event("quota-expired", p); try await settle(p, target: 0)
            try await collect(p, m, r)
        }
        do {
            let (p, m, r) = try make("content-fit-pending")
            try await open(p)
            let old = p.geometry.contentHeight, replacement = try geometry(height: 180)
            p.updateGeometry(replacement); event("content-fit-pending", p)
            try require(p.geometry.contentHeight == old && p.smokeHasPendingGeometry, "open interaction freezes content fit")
            try await close(p, partial: true)
            try require(p.geometry.contentHeight == old && p.smokeWidthProfile == "ordinary-v100", "closing preserves old endpoint and profile")
            try showNotice(p, label: "pending content fit survives quota handoff")
            event("quota-takeover", p)
            try require(p.smokeHasPendingGeometry && p.geometry.contentHeight == old
                && p.smokeWidthProfile == "ordinary-handoff", "bridge preserves frozen content fit")
            try await naturalExpiry(p)
            event("quota-expired", p)
            try await settle(p, target: 0)
            try require(p.geometry.contentHeight == replacement.contentHeight && !p.smokeHasPendingGeometry,
                        "idle adopts pending content fit")
            event("content-fit-adopted", p); try await collect(p, m, r)
        }
        do {
            let (p, m, r) = try make("reduced-motion", reduced: true, enabled: true)
            try await open(p); try await close(p); try await settle(p, target: 0)
            try showNotice(p, label: "reduced quota accepted"); event("quota-takeover", p)
            try await settle(p, target: p.smokeTargetProgress)
            try await playback(.playing, r, m, p)
            p.dismissRefreshNotice(); event("quota-dismissed", p)
            try await settle(p, target: p.smokeTargetProgress)
            try require(p.smokeWidthProfile == "shared-v103" && p.smokeWidthSample.widthVelocity == 0,
                        "reduced motion reaches canonical endpoint without leftover bridge")
            try await collect(p, m, r)
        }
        do {
            let (p, m, r) = try make("bridge-tail-revision", fallback: true, fractional: true)
            try await open(p); try await close(p)
            try await until("late ordinary close still has unsnapped real motion") {
                p.smokeProgress > 0 && p.smokeProgress < 0.004 && p.smokeVelocity < 0
            }
            try showNotice(p, label: "late close accepts quota")
            p.dismissRefreshNotice(); event("late-bridge-redirect", p)
            try await until("main spring reaches zero before bridge") {
                p.smokeProgress == 0 && p.smokeWidthProfile == "ordinary-handoff"
            }
            event("bridge-only-tail", p)
            try await settle(p, target: 0)
            try require(callbacks.indices.dropFirst().contains { index in
                let a = callbacks[index - 1], b = callbacks[index]
                return a["profile"] as? String == "ordinary-handoff" && b["profile"] as? String == "shared-v103"
                    && a["progress"] as? Double == 0 && b["progress"] as? Double == 0
                    && a["frame"] as? [Double] == b["frame"] as? [Double]
                    && a["accessory"] as? Double == b["accessory"] as? Double
                    && a["noticeID"] as? String == b["noticeID"] as? String
                    && a["musicRevision"] as? UInt64 == b["musicRevision"] as? UInt64
                    && (b["revision"] as? UInt64 ?? 0) > (a["revision"] as? UInt64 ?? 0)
            }, "bridge final publication changes revision while every old view observation key stays equal")
            try await collect(p, m, r)
        }
        do {
            let (p, m, r) = try make("bridge-adjacent-retarget-gap", fallback: true)
            try await open(p); try await close(p)
            try await until("gap fixture has a wide ordinary closing contour") {
                p.smokeProgress > 0.35 && p.smokeProgress < 0.7 && p.smokeVelocity < 0
            }
            event("closing-intermediate", p)
            try showNotice(p, label: "closing quota creates a bridge")
            p.dismissRefreshNotice(); event("bridge-redirect", p)
            try await until("real frame publishes the active bridge") {
                p.geometry.widthPresentation != nil && p.smokeWidthProfile == "ordinary-handoff"
            }
            try verifyRetargetGap(p)
            try await settle(p, target: 1); try await close(p); try await settle(p, target: 0)
            try await collect(p, m, r)
        }
        try require(!overflow && traces.count == 8, "complete bounded case set")
        let payload: [String: Any] = ["schema": 1, "cases": traces, "elapsed": CACurrentMediaTime() - began,
            "overflow": overflow, "synthetic": true, "naturalPaint": true, "scanout": false]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try require(data.count < 2_000_000, "bounded trace bytes")
        print("ORDINARY_MOTION_TRACE_JSON: \(String(decoding: data, as: UTF8.self))")
    }
    private func rect(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    private func collect(_ p: IslandPanelController, _ m: MusicLyricsController, _ r: OrdinaryMotionReader) async throws {
        try await dwell(0.05)
        captureHandoff(p)
        if caseName == "bridge-tail-revision" || caseName == "bridge-adjacent-retarget-gap" {
            try require(!callbacks.isEmpty && callbacks.allSatisfy { $0["source"] as? String == "dispatch-60hz" },
                        "gap/tail fixture uses the actual nonprojecting dispatch frame source")
        }
        let commits = p.smokeRenderCommits, paints = p.smokePaintHistory.filter { $0.frame.frameRevision > 0 }
        try require(!p.smokeHistoryOverflow && !p.smokePaintHistoryOverflow && !commits.isEmpty && !paints.isEmpty,
                    "natural frame and paint histories are bounded and nonempty")
        let byRevision = Dictionary(uniqueKeysWithValues: commits.map { ($0.revision, $0) })
        for paint in paints {
            guard let c = byRevision[paint.frame.frameRevision] else { throw Failure(label: "paint missing commit") }
            let contour = IslandContour(rect: c.geometry.contourRect(progress: c.progress), progress: c.progress,
                cornerAdjustment: c.geometry.shapeCalibration.corner, referenceDepth: c.geometry.notch.height)
            try require(paint.observed >= c.observed && paint.frame.progress == c.progress
                && paint.frame.contour == contour && c.nativeFrame == c.geometry.frame(progress: c.progress)
                && paint.frame.viewport == c.nativeFrame.size && paint.actualViewport == c.nativeFrame.size
                && paint.nativeFrameSampledAtPaint && paint.nativeFrame == c.nativeFrame
                && paint.nativeContentBounds == CGRect(origin: .zero, size: c.nativeFrame.size)
                && paint.bodyBounds == paint.frame.bodyPath.boundingRect
                && paint.bodyBounds == contourPath(contour, inset: 0, closed: true).boundingRect
                && paint.railBounds == contourPath(contour, inset: 2, closed: false).boundingRect,
                "natural Canvas body/clip input and rail agree with contemporaneous native frame")
        }
        try require(NSApp.keyWindow === initialKey && p.motionProbe.nonKey && p.placementIsValid, "native panel preserves placement and focus")
        m.stop(); p.stop(); await r.stop()
        let drainDeadline = CACurrentMediaTime() + 1
        while !(await r.isStoppedAndDrained()) && CACurrentMediaTime() < drainDeadline { try await dwell(0.005) }
        let readCount = await r.returnedCount()
        try await dwell(0.03)
        let drained = await r.isStoppedAndDrained(), finalReadCount = await r.returnedCount()
        try require(p.smokeStopped && drained && finalReadCount == readCount,
                    "retired panel and actual provider shutdown are stable")
        let commitRows: [[String: Any]] = commits.map { c in
            var expected = c.geometry; expected.widthPresentation = nil
            let sample = c.geometry.widthPresentation?.sample ?? c.geometry.widthSample(progress: c.progress)
            let ordinary = expected.widthSample(progress: c.progress)
            let q = min(1, max(0, c.progress / c.geometry.updateProgress)), smooth = q * q * (3 - 2 * q)
            let oldWidth = Double(c.geometry.contourFrame.width) + Double(expected.contourRect(progress: 1).width - c.geometry.contourFrame.width) * smooth
            let oldCenter = Double(c.geometry.calibratedNotch.midX) + Double(expected.expandedContentCenterX - c.geometry.calibratedNotch.midX) * smooth
            return ["revision": c.revision, "observed": c.observed, "progress": c.progress,
                "frame": rect(c.nativeFrame), "contour": rect(c.geometry.contourRect(progress: c.progress)),
                "ordinary": c.geometry.ordinaryHoverWidth, "width": sample.width, "center": sample.center,
                "expectedWidth": c.geometry.ordinaryHoverWidth ? oldWidth : ordinary.width,
                "expectedCenter": c.geometry.ordinaryHoverWidth ? oldCenter : ordinary.center,
                "owner": String(describing: c.owner), "target": c.target]
        }
        let paintRows: [[String: Any]] = paints.map { a in
            ["sequence": a.sequence, "revision": a.frame.frameRevision, "observed": a.observed,
             "progress": a.frame.progress, "frame": rect(a.nativeFrame), "content": rect(a.nativeContentBounds),
             "viewport": [Double(a.actualViewport.width), Double(a.actualViewport.height)],
             "contour": rect(a.frame.contour.rect), "sampledAtPaint": a.nativeFrameSampledAtPaint,
             "bodyBounds": rect(a.bodyBounds), "clipBounds": rect(a.frame.bodyPath.boundingRect),
             "railBounds": rect(a.railBounds), "expectedRailBounds": rect(a.frame.railPath.boundingRect),
             "noticeID": a.frame.noticeID?.uuidString ?? "", "musicRevision": a.frame.musicRevision,
             "accessory": a.frame.accessoryProgress]
        }
        let readRows: [[String: Any]] = await r.history().map {
            ["id": $0.id, "started": $0.started, "released": $0.released,
             "returned": $0.returned, "state": $0.state, "prompt": $0.prompt]
        }
        var close: [String: Any] = [:]
        if let value = p.closeReceipt {
            close = ["requested": value.requestedAt, "rendered": value.renderedAt ?? -1,
                     "painted": value.paintedAt ?? -1, "completed": value.completedAt ?? -1,
                     "outcome": String(describing: value.outcome)]
        }
        traces.append(["close": close, "reads": readRows, "noticeRecords": noticeRecords, "gapRecords": gapRecords, "name": caseName, "events": events, "handoffs": handoffs, "callbacks": callbacks, "commits": commitRows,
            "screen": rect(screen.frame),
            "paints": paintRows, "stopped": p.smokeStopped, "readerDrained": await r.isStoppedAndDrained(),
            "readsReturned": readCount, "sameFrameBodyClipRail": true])
    }
    private func finish(_ success: Bool) {
        guard !finished else { return }; finished = true
        stop()
        print(success ? "ORDINARY_MOTION_OK: cases=8 deadline=60 synthetic=true naturalPaint=true scanout=false" : "ORDINARY_MOTION_FAILED: bounded native ordinary motion verification failed")
        completion(success)
    }
    func stop() {
        watchdog?.invalidate(); watchdog = nil; task?.cancel(); task = nil
        panels.forEach { $0.stop() }; controllers.forEach { $0.stop() }
        for reader in readers { Task { await reader.stop() } }
    }
}

private struct OrdinaryReadReceipt: Sendable {
    let id: Int
    let started: Double
    var released: Double = 0
    var returned: Double = 0
    var state = "pending"
    let prompt: Bool
}
private actor OrdinaryMotionReader: MusicSnapshotProvider {
    private var records: [OrdinaryReadReceipt] = []
    private var continuation: CheckedContinuation<MusicReadResult, Never>?
    private var returned = 0
    private var activeReads = 0
    private var stopped = false
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult {
        guard !stopped else { return .unavailable(.cancelled) }
        activeReads += 1
        let index = records.count
        records.append(OrdinaryReadReceipt(id: index + 1, started: ProcessInfo.processInfo.systemUptime,
                                           prompt: allowPermissionPrompt))
        let result = await withCheckedContinuation { continuation = $0 }
        returned += 1; activeReads -= 1
        records[index].returned = ProcessInfo.processInfo.systemUptime
        return result
    }
    func history() -> [OrdinaryReadReceipt] { records }
    func hasPending() -> Bool { continuation != nil }
    func returnedCount() -> Int { returned }
    func isStoppedAndDrained() -> Bool { stopped && continuation == nil && activeReads == 0 }
    func release(_ state: MusicPlaybackState) -> Bool {
        guard let pending = continuation,
            let track = MusicTrackIdentity(title: "Ordinary Native Fixture", artist: "Synthetic", album: "Test", duration: 120),
            let value = MusicPlaybackSnapshot(track: track, state: state, position: 1,
                observedAt: ProcessInfo.processInfo.systemUptime) else { return false }
        records[records.count - 1].released = ProcessInfo.processInfo.systemUptime
        records[records.count - 1].state = state == .playing ? "playing" : "paused"
        continuation = nil; pending.resume(returning: .snapshot(value)); return true
    }
    func stop() {
        stopped = true; let pending = continuation; continuation = nil
        if let pending {
            records[records.count - 1].released = ProcessInfo.processInfo.systemUptime
            records[records.count - 1].state = "cancelled"
            pending.resume(returning: .unavailable(.cancelled))
        }
    }
}
#endif
