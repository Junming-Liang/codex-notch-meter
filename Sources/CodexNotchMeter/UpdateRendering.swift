#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Demo-only observations of the real panel and normal main-run-loop view updates.
/// Synthetic pointer input is local to this controller; no system events are posted.
/// This is neither a screen capture nor GPU scanout or physical smoothness evidence.
@MainActor
final class UpdateRenderHarness: NSObject {
    private enum Scenario: String, CaseIterable {
        case initial, fractionalDecrease, unchanged, readFailed
        case movingPromotion, coalescing, armedPromotion, reducedMotion, retiredTimer
    }
    private enum Phase: String {
        case idle, opening, holding, closing, closed
        case expanded, promotedHold, refitOpening, refitExpanded, refitSettled, refitClosing
        case replacementHold, stopped
    }
    private struct Fixture {
        let name: String
        let snapshot: QuotaSnapshot
        let notice: RefreshNotice
    }
    private let model: MeterModel
    private let screen: NSScreen
    private let completion: (Bool) -> Void
    private var controller: IslandPanelController?
    private var geometry: IslandGeometry?
    private var refittedGeometry: IslandGeometry?
    private var fixtures: [Fixture] = []
    private var timer: Timer?
    private var started = false
    private var finished = false
    private var passed = true
    private var scenarioIndex = 0
    private var phase: Phase = .idle
    private var startedAt: TimeInterval = 0
    private var phaseStarted: TimeInterval = 0
    private var scenarioCreatedAt: TimeInterval = 0
    private var shownAt: TimeInterval = 0
    private var targetReachedAt: TimeInterval?
    private var replacedAt: TimeInterval = 0
    private var closingAt: TimeInterval?
    private var lastSampleCount = 0
    private var totalSamples = 0
    private var nativeProbes = 0
    private var expandedChecks = 0
    private var targetVerified = false
    private var oldDeadlineVerified = false
    private var retainsNoticeWhileClosing = false
    private var activeNotice: RefreshNotice?
    private weak var initialKey: NSWindow?
    private var scenario: Scenario { Scenario.allCases[scenarioIndex] }
    private var reduced: Bool { scenario == .reducedMotion }

    init(model: MeterModel, screen: NSScreen, completion: @escaping (Bool) -> Void) {
        self.model = model; self.screen = screen; self.completion = completion
        super.init()
    }

    func start() {
        guard !started, !finished else { return }
        started = true
        guard model.demo, CommandLine.arguments.contains("--update-test") else { finish(false); return }
        startedAt = CACurrentMediaTime(); initialKey = NSApp.keyWindow
        do { fixtures = try makeFixtures() }
        catch { SmokeDiagnostics.mark("update synthetic parser fixture failed"); finish(false); return }
        guard let base = makeGeometry(contentHeight: 180), let fitted = makeGeometry(contentHeight: 300) else {
            SmokeDiagnostics.mark("update synthetic hosted-screen geometry unavailable"); finish(false); return
        }
        geometry = base; refittedGeometry = fitted
        check(base.updateProgress > 0 && base.updateProgress < 1
            && base.frame(progress: base.updateProgress).height < base.frame(progress: 1).height
            && base.hasSameAnchor(as: fitted) && fitted.contentHeight > base.contentHeight,
            "intermediate target and same-anchor content-fit endpoints")
        let savedPreference = UserDefaults.standard.object(forKey: "refreshNoticesEnabled") as? Bool
        model.refreshNoticesEnabled = false; model.refreshNoticesEnabled = true
        check((UserDefaults.standard.object(forKey: "refreshNoticesEnabled") as? Bool) == savedPreference, "demo notice setting never persists")
        guard passed else { finish(false); return }
        startScenario()
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func makeGeometry(contentHeight: CGFloat) -> IslandGeometry? {
        let frame = screen.frame, width: CGFloat = 220, inset: CGFloat = 32
        let left = frame.midX - width / 2, right = frame.midX + width / 2
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: Double(inset),
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - inset, width: left - frame.minX, height: inset),
            auxiliaryRight: CGRect(x: right, y: frame.maxY - inset, width: frame.maxX - right, height: inset)) else { return nil }
        return IslandGeometry(notch: notch, screen: frame, backingScale: screen.backingScaleFactor, contentHeight: contentHeight)
    }

    private func makeFixtures() throws -> [Fixture] {
        // Relative dates remain fresh throughout this bounded run. Identity is synthetic,
        // stays in the parser/tracker, and is never printed or passed to a presentation.
        let base = Date().addingTimeInterval(-30), reset = base.addingTimeInterval(3600)
        func snapshot(used: Double, offset: TimeInterval) throws -> QuotaSnapshot {
            let json = "{\"accountId\":\"synthetic-native-update\",\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)}}}"
            return try QuotaParser.parse(Data(json.utf8), fetchedAt: base.addingTimeInterval(offset))
        }
        let initial = try snapshot(used: 40.125, offset: 0)
        let decreased = try snapshot(used: 40.375, offset: 5)
        let unchanged = try snapshot(used: 40.375, offset: 10)
        var tracker = QuotaUpdateTracker()
        let first = tracker.record(initial, at: initial.fetchedAt)
        let second = tracker.record(decreased, at: decreased.fetchedAt)
        let third = tracker.record(unchanged, at: unchanged.fetchedAt)
        let failed = tracker.recordFailure(at: base.addingTimeInterval(15))
        func fixture(_ name: String, _ snapshot: QuotaSnapshot, _ result: QuotaUpdate) -> Fixture {
            Fixture(name: name, snapshot: snapshot,
                notice: RefreshNotice(id: UUID(), receivedAt: result.observedAt, result: result,
                    bucketID: snapshot.buckets.first?.id, window: snapshot.buckets.first?.windows.first))
        }
        let values = [fixture("initial", initial, first), fixture("fractional-decrease", decreased, second),
            fixture("unchanged", unchanged, third), fixture("failed-read", unchanged, failed)]
        check(values[0].notice.title == "额度已刷新" && values[0].notice.detail == "首次读取，不计算消耗"
            && values[0].notice.change == .updated(reason: .initial) && first.previousFetchedAt == nil,
            "initial label never invents consumption")
        check(values[1].notice.title == "额度已更新" && values[1].notice.detail == "本次减少 0.25 个百分点"
            && values[1].notice.change == .decreased(percentagePoints: 0.25)
            && second.previousFetchedAt == initial.fetchedAt && second.fetchedAt == decreased.fetchedAt,
            "fractional delta is absolute percentage points with comparable interval")
        check(QuotaFormatting.percent(59.875) != QuotaFormatting.percent(59.625)
            && QuotaFormatting.points(0.25) == "0.25" && QuotaFormatting.points(0.001) == "<0.01",
            "fractional endpoints stay distinct and tiny decreases never become zero")
        check(values[2].notice.title == "额度未变化" && values[2].notice.detail == "与上次可比读取相同"
            && third.kind == .unchanged && values[2].notice.change == .unchanged && values[2].notice.holdDuration == 0.8,
            "unchanged label never claims new consumption")
        check(values[3].notice.title == "额度读取未完成" && values[3].notice.detail == "本次读取失败，稍后重试"
            && failed.kind == .readFailed && failed.fetchedAt == nil && failed.previousFetchedAt == nil
            && values[3].notice.change == nil,
            "failure uses neutral wording without success or comparison claim")
        return values
    }

    private func startScenario() {
        controller?.stop()
        guard let geometry else { finish(false); return }
        targetReachedAt = nil; closingAt = nil; targetVerified = false; oldDeadlineVerified = false
        lastSampleCount = 0; activeNotice = nil; retainsNoticeWhileClosing = false
        let creationStarted = CACurrentMediaTime()
        let index = min(scenarioIndex, fixtures.count - 1)
        model.setUpdateFixture(fixtures[index].snapshot)
        scenarioCreatedAt = CACurrentMediaTime()
        controller = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: reduced, motionSample: { [weak self] sample in self?.observe(sample) },
            hovered: {}, refresh: {}, settings: {}, quit: {})
        next(.idle, at: creationStarted)
        SmokeDiagnostics.mark("update scenario=\(scenario.rawValue) actualBacking=\(controller?.panel.backingScaleFactor ?? 0) syntheticCutout=true reducedMotion=\(reduced)")
    }

    private func observe(_ sample: IslandMotionSample) {
        guard let island = controller, !finished else { return }
        totalSamples += 1; lastSampleCount += 1
        if island.smokeNoticeTargetActive && sample.progress == island.geometry.updateProgress && targetReachedAt == nil {
            targetReachedAt = sample.observed
        }
    }

    private func show(_ notice: RefreshNotice, at now: TimeInterval) {
        guard let island = controller else { finish(false); return }
        activeNotice = notice; shownAt = now; targetReachedAt = nil; closingAt = nil; targetVerified = false
        check(island.showRefreshNotice(notice), "notice accepted from collapsed or passive state")
        check(island.smokeNoticeVisible && island.smokeNoticeTargetActive && !island.isInteracting
            && island.smokeTargetProgress == island.geometry.updateProgress
            && island.panel.ignoresMouseEvents, "notice targets intermediate click-through state")
        if reduced {
            targetReachedAt = now
            check(island.smokeProgress == island.geometry.updateProgress && island.smokeVelocity == 0
                && !island.smokeMotionRunning, "Reduce Motion snaps immediately without a motion source")
        }
        next(.opening, at: now)
    }

    @objc private func tick(_ sender: Timer) {
        guard sender === timer, !finished, let island = controller else { return }
        let now = CACurrentMediaTime(), elapsed = now - phaseStarted
        guard now - startedAt < 40, elapsed < 4.5 else {
            SmokeDiagnostics.mark("update deadline scenario=\(scenario.rawValue) phase=\(phase.rawValue) elapsed=\(elapsed) total=\(now-startedAt)")
            finish(false); return
        }
        guard passed else { finish(false); return }
        if phase != .stopped {
            guard nativeFrameValid(island) else { check(false, "native frame/top-edge/nonactivation invariant"); finish(false); return }
        }
        switch phase {
        case .idle where elapsed >= 0.14:
            check(settledNative(island, progress: 0, after: scenarioCreatedAt), "normal-run-loop collapsed viewport")
            let index = scenarioIndex < fixtures.count ? scenarioIndex : 1
            model.setUpdateFixture(fixtures[index].snapshot)
            show(fixtures[index].notice, at: now)
        case .opening:
            if scenario == .movingPromotion, island.smokeProgress > 0.02,
                island.smokeProgress < island.geometry.updateProgress, island.smokeVelocity > 0 {
                promoteWhileMoving(island, at: now)
            } else if island.smokeProgress == island.geometry.updateProgress && !island.smokeMotionRunning {
                if targetReachedAt == nil { targetReachedAt = now }
                next(.holding, at: now)
            }
        case .holding:
            guard let reached = targetReachedAt else { finish(false); return }
            let held = now - reached
            let hold = activeNotice?.holdDuration ?? 2
            if !targetVerified, elapsed >= 0.14 {
                check(settledNative(island, progress: island.geometry.updateProgress, after: shownAt)
                    && island.panel.ignoresMouseEvents && !island.smokeTargetExpanded
                    && island.smokeNoticeVisible && island.smokeNoticeTargetActive,
                    "normal-run-loop intermediate viewport retains notice and passive routing")
                if !reduced { check(lastSampleCount >= 3, "real spring callbacks reached intermediate target") }
                targetVerified = true
            }
            if scenario == .coalescing, targetVerified, held >= 0.65 {
                replaceNotice(island, at: now); return
            }
            if scenario == .armedPromotion, targetVerified, held >= 0.35 {
                promoteArmed(island, at: now); return
            }
            if scenario == .retiredTimer, targetVerified, held >= 0.35 {
                let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame, island.smokeNoticeID)
                check(island.verifyRetiredNoticeIsInert(), "retired real expiry callback is inert")
                island.collapse(); island.beginSmokeExpansion()
                let accepted = island.showRefreshNotice(fixtures[2].notice)
                check(!accepted && island.smokeStopped && island.smokeProgress == before.0
                    && island.smokeVelocity == before.1 && island.panel.frame == before.2
                    && island.smokeNoticeID == before.3, "stopped controller rejects later show/collapse/hover actions")
                next(.stopped, at: now); return
            }
            if !island.smokeNoticeTargetActive {
                check(targetVerified && held >= hold - 0.05 && held <= hold + 0.75,
                    "automatic expiry begins after configured settled hold actual=\(held)")
                closingAt = reached; retainsNoticeWhileClosing = !reduced
                if reduced {
                    check(island.smokeProgress == 0 && !island.smokeMotionRunning && !island.smokeNoticeVisible,
                        "Reduce Motion expires with immediate idle snap and cleared content")
                } else if island.smokeProgress > 0 {
                    check(island.smokeNoticeVisible && island.smokeTargetProgress == 0,
                        "notice remains during continuous closing fade")
                }
                next(.closing, at: now)
            } else if held > hold + 0.75 { check(false, "notice expiry failed to fire within bounded hold") }
        case .closing:
            if island.smokeProgress > 0 {
                check((!retainsNoticeWhileClosing || island.smokeNoticeVisible) && island.panel.ignoresMouseEvents,
                    "closing content remains passive until idle")
            } else if !island.smokeMotionRunning { next(.closed, at: now) }
        case .closed where elapsed >= 0.14:
            check(settledNative(island, progress: 0, after: closingAt ?? phaseStarted)
                && !island.smokeNoticeVisible && !island.smokeNoticeTargetActive && !island.isInteracting
                && island.panel.ignoresMouseEvents, "settled idle clears transient content and timers")
            advanceScenario()
        case .expanded where island.smokeProgress == 1 && !island.smokeMotionRunning:
            next(.promotedHold, at: now)
        case .promotedHold:
            if !targetVerified, elapsed >= 0.14 {
                verifyExpanded(island, after: shownAt)
                check(!island.smokeNoticeVisible && !island.smokeNoticeTargetActive,
                    "full promotion retires notice presentation")
                targetVerified = true
            }
            if elapsed >= 2.20 {
                check(targetVerified && island.smokeTargetExpanded && island.smokeProgress == 1
                    && !island.smokeMotionRunning && island.isInteracting,
                    "hover expansion survives superseded notice deadline")
                if scenario == .movingPromotion, let geometry {
                    check(island.geometry == geometry, "content-fit change remains deferred throughout open interaction")
                }
                island.collapse(); closingAt = now
                next(scenario == .movingPromotion ? .refitClosing : .closing, at: now)
            }
        case .refitClosing where island.smokeProgress == 0 && !island.smokeMotionRunning:
            guard let refittedGeometry else { finish(false); return }
            check(island.geometry == refittedGeometry, "deferred content-fit endpoint adopted at idle")
            next(.refitOpening, at: now)
        case .refitOpening where elapsed >= 0.14:
            check(settledNative(island, progress: 0, after: closingAt ?? phaseStarted), "refit preserves idle anchor and viewport")
            island.beginSmokeExpansion(); shownAt = now; next(.refitExpanded, at: now)
        case .refitExpanded where island.smokeProgress == 1 && !island.smokeMotionRunning:
            next(.refitSettled, at: now)
        case .refitSettled where elapsed >= 0.14:
            verifyExpanded(island, after: shownAt)
            check(island.geometry == refittedGeometry, "next expansion uses new content-fit height")
            island.collapse(); closingAt = now; next(.closing, at: now)
        case .replacementHold:
            verifyReplacement(island, at: now)
        case .stopped where elapsed >= 0.14:
            check(island.smokeStopped && !island.smokeMotionRunning && island.panel.ignoresMouseEvents,
                "retired controller remains stopped after normal-run-loop dwell")
            advanceScenario()
        default: break
        }
    }

    private func promoteWhileMoving(_ island: IslandPanelController, at now: TimeInterval) {
        let before = (island.smokeProgress, island.smokeVelocity)
        let previousTarget = island.smokeTargetProgress
        // One inside event must promote immediately. The regular helper then makes
        // the same request again, checking that no second dwell restarts the spring.
        island.smokePointer(inside: true, now: now)
        let trace = island.smokeRetarget
        let continuous = trace.map { event in
            var expected = event.before
            expected.advance(target: previousTarget, elapsed: event.consumedElapsed, reduceMotion: false)
            return event.before.progress == before.0 && event.before.velocity == before.1
                && abs(expected.progress - event.integrated.progress) < 1e-12
                && abs(expected.velocity - event.integrated.velocity) < 1e-12
                && event.integrated.velocity > 0
                && abs(island.smokeProgress - event.integrated.progress) < 1e-12
                && abs(island.smokeVelocity - event.integrated.velocity) < 1e-12
        } ?? false
        check(continuous && island.smokeTargetExpanded && island.smokeTargetProgress == 1
            && !island.smokeNoticeTargetActive, "single pointer event promotes without dwell or position/velocity reset")
        let promoted = (island.smokeProgress, island.smokeVelocity)
        island.beginSmokeExpansion()
        check(island.smokeProgress == promoted.0 && island.smokeVelocity == promoted.1,
            "repeated expansion request preserves current spring state")
        if let refittedGeometry, let geometry {
            let frame = island.panel.frame
            island.updateGeometry(refittedGeometry)
            check(island.geometry == geometry && island.panel.frame == frame
                && island.smokeProgress == promoted.0 && island.smokeVelocity == promoted.1,
                "content-fit update is deferred while opening")
        } else { check(false, "missing refit fixture") }
        targetVerified = false; shownAt = now; next(.expanded, at: now)
    }

    private func promoteArmed(_ island: IslandPanelController, at now: TimeInterval) {
        let progress = island.smokeProgress
        island.beginSmokeExpansion()
        check(island.smokeTargetExpanded && island.smokeTargetProgress == 1 && !island.smokeNoticeTargetActive
            && island.smokeProgress == progress && island.smokeVelocity == 0,
            "hover promotion cancels armed expiry without resetting settled position")
        targetVerified = false; shownAt = now; next(.expanded, at: now)
    }

    private func replaceNotice(_ island: IslandPanelController, at now: TimeInterval) {
        guard let activeNotice else { finish(false); return }
        let before = (island.smokeProgress, island.smokeVelocity, island.panel.frame)
        check(island.showRefreshNotice(activeNotice), "repeated notice accepted without another panel")
        let original = fixtures[1].notice
        let replacement = RefreshNotice(id: UUID(), receivedAt: original.receivedAt, result: original.result, bucketID: original.bucketID, window: original.window)
        check(island.showRefreshNotice(replacement), "newer notice replaces existing passive content")
        self.activeNotice = replacement; replacedAt = now
        check(island.smokeNoticeID == replacement.id && island.smokeNoticeTargetActive
            && island.smokeProgress == before.0 && island.smokeVelocity == before.1
            && island.panel.frame == before.2 && island.panel.ignoresMouseEvents,
            "repeat and newer notice coalesce with unchanged position/velocity")
        next(.replacementHold, at: now)
    }

    private func verifyReplacement(_ island: IslandPanelController, at now: TimeInterval) {
        guard let reached = targetReachedAt, let activeNotice else { finish(false); return }
        let sinceOriginal = now - reached, sinceReplacement = now - replacedAt
        if sinceOriginal >= 2.15 && sinceReplacement < 1.85 && !oldDeadlineVerified {
            check(island.smokeNoticeTargetActive && island.smokeNoticeID == activeNotice.id
                && island.smokeProgress == island.geometry.updateProgress && island.panel.ignoresMouseEvents,
                "superseded timer cannot dismiss newer notice at old deadline")
            oldDeadlineVerified = true
        }
        if !island.smokeNoticeTargetActive {
            check(oldDeadlineVerified && sinceReplacement >= 1.95 && sinceReplacement <= 2.75,
                "replacement gets its own two-second hold actual=\(sinceReplacement)")
            closingAt = replacedAt; retainsNoticeWhileClosing = true; next(.closing, at: now)
        } else if sinceReplacement > 2.75 { check(false, "replacement expiry did not retire") }
    }

    private func nativeFrameValid(_ island: IslandPanelController) -> Bool {
        let probe = island.motionProbe, expected = island.geometry.frame(progress: island.smokeProgress)
        nativeProbes += 1
        return probe.visible && probe.nonKey && NSApp.keyWindow === initialKey && island.placementIsValid
            && probe.frame == expected && abs(probe.frame.maxY - screen.frame.maxY) < 0.001
            && probe.contentBounds == CGRect(origin: .zero, size: probe.frame.size)
            && island.smokeProgress.isFinite && island.smokeVelocity.isFinite
    }

    private func settledNative(_ island: IslandPanelController, progress: Double, after: TimeInterval) -> Bool {
        let probe = island.motionProbe, expected = island.geometry.frame(progress: progress)
        let valid = nativeFrameValid(island) && !probe.running && probe.requestedProgress == progress
            && probe.renderedProgress == progress && probe.renderedAt >= after
            && probe.frame == expected && probe.viewport == expected.size
            && probe.layerPresentation == CGRect(origin: .zero, size: expected.size)
        SmokeDiagnostics.mark("update normal-runloop scenario=\(scenario.rawValue) progress=\(progress) frame=\(probe.frame) viewport=\(probe.viewport) rendered=\(probe.renderedProgress) renderedAt=\(probe.renderedAt) presentation=\(String(describing: probe.layerPresentation)) valid=\(valid)")
        return valid
    }

    private func verifyExpanded(_ island: IslandPanelController, after: TimeInterval) {
        // These checks use the measured SwiftUI Quit preference after a real run-loop
        // dwell, never layoutSubtreeIfNeeded or a forced bitmap layout.
        check(settledNative(island, progress: 1, after: after)
            && island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting(),
            "expanded native viewport and measured Quit visibility/routing")
        expandedChecks += 1
    }

    private func check(_ value: Bool, _ label: String) {
        passed = value && passed
        SmokeDiagnostics.mark("update \(label) valid=\(value)")
    }
    private func next(_ phase: Phase, at now: TimeInterval) { self.phase = phase; phaseStarted = now }
    private func advanceScenario() {
        scenarioIndex += 1
        if scenarioIndex < Scenario.allCases.count { startScenario() }
        else { finish(passed && totalSamples >= 20 && nativeProbes >= 20 && expandedChecks == 3) }
    }
    private func finish(_ valid: Bool) {
        guard !finished else { return }
        finished = true; stop()
        SmokeDiagnostics.mark("update samples=\(totalSamples) nativeProbes=\(nativeProbes) expandedQuitChecks=\(expandedChecks) elapsed=\(CACurrentMediaTime()-startedAt) scanout=false physicalFeelUnverified=true")
        print(valid ? "UPDATE_OK: synthetic labels, native intermediate hold/expiry, continuous hover promotion, coalescing, reduced motion, deferred content fit and retired callbacks passed" : "UPDATE_FAILED: native update-pill contract failed")
        completion(valid)
    }
    func stop() { timer?.invalidate(); timer = nil; controller?.stop() }
}
#endif
