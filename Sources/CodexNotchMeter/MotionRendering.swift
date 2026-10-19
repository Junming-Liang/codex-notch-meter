#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Real native callbacks and own-window observations under synthetic UI updates.
/// No bitmap capture occurs in the timed pass. This is not perceptual or hardware QA.
@MainActor
final class NativeMotionHarness: NSObject {
    private let model: MeterModel
    private let geometry: IslandGeometry
    // This harness runs only ordinary no-Music hover cycles. Its boundary inputs
    // and historical paint expectations must use that cycle's latched width map,
    // not the shared compact Music/notice map stored in the initial geometry.
    private var expectedMotionGeometry: IslandGeometry {
        var value = geometry
        value.ordinaryHoverWidth = true
        return value
    }
    private let completion: (Bool) -> Void
    private let profiles: [IslandMotionProfile] = [.synchronousBaseline, .adaptive, .timerFallback]
    private var profileIndex = 0
    private var controller: IslandPanelController?
    private var timer: Timer?
    private var samples: [IslandMotionSample] = []
    private var initialApplyTime: TimeInterval = 0
    private var probes: [IslandMotionProbe] = []
    private var paints: [(receipt: IslandPaintReceipt, active: Bool)] = []
    private var summaries: [(String, Double, Double)] = []
    private var phase = 0
    private var phaseStarted = CACurrentMediaTime()
    private var lastLoad = CACurrentMediaTime()
    private var lastColorLoad = CACurrentMediaTime()
    private var loadCount = 0
    private var passed = true
    private var heldPointer: CGPoint?
    private struct Pacing {
        let name: String
        let began: TimeInterval
        let origin: Double
        let target: Double
        var at95: TimeInterval?
        var at99: TimeInterval?
    }
    private var pacing: Pacing?
    private var pacingResults: [Pacing] = []
    private weak var initialKey: NSWindow?
    init(model: MeterModel, geometry: IslandGeometry, completion: @escaping (Bool) -> Void) {
        self.model = model; self.geometry = geometry; self.completion = completion
        super.init()
    }
    func start() {
        guard model.demo, CommandLine.arguments.contains("--motion-test") else { finish(false); return }
        model.theme = .rainbow
        let historyControls = verifyPresentationHistoryControls() && verifyViewUpdateHistoryControls()
        SmokeDiagnostics.mark("motion presentation/view replacement-age controls valid=\(historyControls)")
        guard historyControls else { finish(false); return }
        initialKey = NSApp.keyWindow
        startProfile()
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(check(_:)), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func startProfile() {
        controller?.stop(); samples = []; probes = []; paints = []; phase = 0; phaseStarted = CACurrentMediaTime(); loadCount = 0; heldPointer = nil; pacing = nil; pacingResults = []
        let profile = profiles[profileIndex]
        initialApplyTime = phaseStarted
        model.setMotionFixture(remaining: 72)
        lastLoad = CACurrentMediaTime(); lastColorLoad = lastLoad
        controller = IslandPanelController(model: model, geometry: geometry, startPolling: false, reducedMotionOverride: false,
            motionProfile: profile, motionSample: { [weak self] sample in
                guard let self else { return }
                if self.samples.count < 1500 { self.samples.append(sample) } else { self.passed = false }
                self.observePacing(sample)
            }, hovered: {}, refresh: {}, settings: {}, quit: {})
        SmokeDiagnostics.mark("motion profile=\(profile.rawValue) baselineScope=old-synchronous-layout-timer/shared-current-spring-canvas buckets=4 windows=8 actualBacking=\(controller?.panel.backingScaleFactor ?? 0)")
    }
    private func next(_ phase: Int, now: TimeInterval) { self.phase = phase; phaseStarted = now }
    @objc private func check(_ sender: Timer) {
        guard sender === timer, let island = controller else { return }
        let now = CACurrentMediaTime(), elapsed = now - phaseStarted
        if elapsed > 2.5 { SmokeDiagnostics.mark("motion phase deadline profile=\(profiles[profileIndex]) phase=\(phase) progress=\(island.smokeProgress)"); finish(false); return }
        // Repeat the same modest main-thread UI load for every profile. This never polls Codex.
        if now - lastLoad >= 0.05 {
            lastLoad = now; loadCount += 1
            model.setMotionFixture(remaining: Double(60 + loadCount % 30))
        }
        if now - lastColorLoad >= 1.0 / 15 {
            lastColorLoad = now
            model.setSkinPhaseForTesting(Double(loadCount % 120) / 120)
        }
        if phase == 4, let heldPointer { island.smokePointer(at: heldPointer, now: now) }
        let probe = island.motionProbe
        if let paint = island.paintReceipt, paints.last?.receipt.sequence != paint.sequence {
            paints.append((paint, probe.running))
        }
        if probes.count < 2000 { probes.append(probe) } else { passed = false }
        let manyData = model.snapshot?.buckets.count == 4 && model.snapshot?.buckets.allSatisfy { $0.windows.count == 2 } == true
        let native = manyData && probe.visible && probe.nonKey && NSApp.keyWindow === initialKey
            && abs(probe.frame.maxY - geometry.screen.maxY) < 0.01
            && probe.contentBounds.origin == .zero && probe.contentBounds.size == probe.frame.size
        passed = native && passed
        switch phase {
        case 0 where elapsed >= 0.25:
            island.beginSmokeExpansion()
            passed = island.verifyNonadvancingFramesAreInert() && passed
            next(1, now: now)
        case 1 where island.smokeProgress >= 0.35:
            crossEdge(inside: false, now: now); next(2, now: now)
        case 2 where elapsed >= 0.06:
            crossEdge(inside: true, now: now); passed = island.smokeTargetExpanded && passed
            next(11, now: now)
        case 11 where elapsed >= 0.06:
            crossEdge(inside: false, now: now); next(12, now: now)
        case 12 where elapsed >= 0.06:
            crossEdge(inside: true, now: now); passed = island.smokeTargetExpanded && passed
            next(13, now: now)
        case 13 where elapsed >= 0.06:
            crossEdge(inside: false, now: now); next(14, now: now)
        case 14 where elapsed >= 0.24:
            crossEdge(inside: false, now: now)
            passed = !island.smokeTargetExpanded && passed
            next(3, now: now)
        case 3 where island.smokeProgress < 0.9 && island.smokeVelocity < -0.1:
            let before = (island.smokeProgress, island.smokeVelocity)
            heldPointer = edgePoint(inside: true)
            if let heldPointer { island.smokePointer(at: heldPointer, now: now) }
            // Compare states at the SAME event time. Integrating the old target
            // since its last scheduled frame is normal motion, not a reversal jump.
            let trace = island.smokeRetarget
            let continuous = trace.map { event in
                var expected = event.before
                expected.advance(expanded: event.previousTarget, elapsed: event.consumedElapsed, reduceMotion: false)
                return event.before.progress == before.0 && event.before.velocity == before.1
                    && event.eventTime >= now
                    && abs(expected.progress - event.integrated.progress) < 1e-12
                    && abs(expected.velocity - event.integrated.velocity) < 1e-12
                    && !event.previousTarget && event.nextTarget && island.smokeTargetExpanded
                    && event.integrated.velocity < 0
                    && abs(island.smokeProgress - event.integrated.progress) < 1e-12
                    && abs(island.smokeVelocity - event.integrated.velocity) < 1e-12
            } ?? false
            passed = continuous && island.verifyNonadvancingFramesAreInert() && passed
            if let event = trace {
                SmokeDiagnostics.mark("motion reentry profile=\(profiles[profileIndex]) priorScheduled=\(event.scheduledTime) eventTime=\(event.eventTime) consumedElapsed=\(event.consumedElapsed) before=[\(event.before.progress),\(event.before.velocity)] integrated=[\(event.integrated.progress),\(event.integrated.velocity)] returned=[\(island.smokeProgress),\(island.smokeVelocity)] immediateTarget=\(island.smokeTargetExpanded) continuous=\(continuous)")
            }
            // After the near-boundary reversal, move the synthetic pointer into
            // the body for the hold. A fixed near-edge point could legitimately
            // leave the visible side as the compact shoulder curves grow inward.
            let heldFrame = expectedMotionGeometry.frame(progress: island.smokeProgress)
            heldPointer = CGPoint(x: heldFrame.midX, y: heldFrame.midY)
            if let heldPointer {
                passed = expectedMotionGeometry.hoverContains(heldPointer, progress: island.smokeProgress) && passed
                island.smokePointer(at: heldPointer, now: now)
            }
            beginPacing("reversal", island: island)
            next(4, now: now)
        case 4 where island.smokeProgress == 1 && !island.smokeMotionRunning:
            heldPointer = nil; next(5, now: now)
        case 5 where elapsed >= 0.10:
            let expanded = island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting()
            let viewUpdated = probe.viewport == probe.frame.size && probe.renderedProgress == 1
            passed = expanded && viewUpdated && passed
            SmokeDiagnostics.mark("motion expanded view-update profile=\(profiles[profileIndex]) viewport=\(probe.viewport) content=\(probe.contentBounds) presentation=\(String(describing: probe.layerPresentation)) viewUpdated=\(viewUpdated) quit=\(expanded)")
            island.collapse(); beginPacing("close", island: island)
            passed = island.verifyNonadvancingFramesAreInert() && passed
            next(6, now: now)
        case 6 where island.smokeProgress == 0 && !island.smokeMotionRunning:
            next(7, now: now)
        case 7 where elapsed >= 0.10:
            let viewUpdated = probe.viewport == geometry.frame(progress: 0).size && probe.renderedProgress == 0
            passed = viewUpdated && passed
            SmokeDiagnostics.mark("motion recollapse view-update profile=\(profiles[profileIndex]) viewUpdated=\(viewUpdated) frame=\(probe.frame) viewport=\(probe.viewport)")
            island.beginSmokeExpansion(); beginPacing("open", island: island); next(8, now: now)
        case 8 where island.smokeProgress == 1 && !island.smokeMotionRunning:
            next(9, now: now)
        case 9 where elapsed >= 0.10:
            passed = island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting() && passed
            island.collapse(); next(10, now: now)
        case 10 where island.smokeProgress < 0.7 && island.smokeProgress > 0 && island.smokeVelocity < 0:
            summarize()
            let retired = island.verifyRetiredMotionIsInert()
            passed = retired && passed
            SmokeDiagnostics.mark("motion retired source and stopped actions inert=\(retired)")
            profileIndex += 1
            if profileIndex < profiles.count { startProfile() }
            else {
                for summary in summaries { SmokeDiagnostics.mark("motion comparison profile=\(summary.0) applyP95Seconds=\(summary.1) callbackP95Seconds=\(summary.2)") }
                finish(passed)
            }
        default: break
        }
    }
    private func beginPacing(_ name: String, island: IslandPanelController) {
        if let pacing { pacingResults.append(pacing) }
        guard let trace = island.smokeRetarget else { passed = false; return }
        pacing = Pacing(name: name, began: trace.eventTime, origin: trace.integrated.progress,
            target: trace.nextTarget ? 1 : 0)
    }
    private func observePacing(_ sample: IslandMotionSample) {
        guard var value = pacing, abs(value.target - value.origin) > 0.001 else { return }
        let residual = abs(value.target - sample.progress) / abs(value.target - value.origin)
        if residual <= 0.05 && value.at95 == nil { value.at95 = sample.observed - value.began }
        if residual <= 0.01 && value.at99 == nil { value.at99 = sample.observed - value.began }
        pacing = value
    }
    private func edgePoint(inside: Bool) -> CGPoint? {
        guard let island = controller else { return nil }
        let p = island.smokeProgress, frame = expectedMotionGeometry.frame(progress: p), contour = expectedMotionGeometry.contourRect(progress: p)
        // The straight side follows the shared contour's inward shoulder, not
        // the rectangular host edge. Its midpoint is outside both circular turns.
        let shoulder = min(12 * CGFloat(p), max(0, contour.width / 4 - 2))
        let point = CGPoint(x: frame.minX + contour.maxX - shoulder + (inside ? -0.25 : 0.25),
            y: frame.maxY - contour.midY)
        let classified = expectedMotionGeometry.hoverContains(point, progress: p)
        passed = (classified == inside) && passed
        SmokeDiagnostics.mark("motion boundary classification progress=\(p) expectedInside=\(inside) actualInside=\(classified)")
        return point
    }
    private func crossEdge(inside: Bool, now: TimeInterval) {
        guard let island = controller, let point = edgePoint(inside: inside) else { passed = false; return }
        island.smokePointer(at: point, now: now)
        SmokeDiagnostics.mark("motion boundary profile=\(profiles[profileIndex]) point=\(point) inside=\(inside) progress=\(island.smokeProgress) targetExpanded=\(island.smokeTargetExpanded)")
    }
    private func recentPresentationSizes(at time: TimeInterval,
        frames: [(time: TimeInterval, size: CGSize)], initial: CGSize) -> [CGSize] {
        let history = [(time: -Double.infinity, size: initial)] + frames.filter { $0.time <= time }
        return history.indices.filter { index in
            index == history.count - 1 || time - history[index + 1].time <= 0.1
        }.map { history[$0].size }
    }
    private func presentationMatches(_ bounds: CGRect, recent: [CGSize]) -> Bool {
        bounds.origin == .zero && recent.contains {
            abs($0.width - bounds.width) < 0.01 && abs($0.height - bounds.height) < 0.01
        }
    }
    private func verifyPresentationHistoryControls() -> Bool {
        let old = CGSize(width: 381, height: 512), new = CGSize(width: 313, height: 302)
        let history = [(time: 10.0, size: new)]
        func matches(_ size: CGSize, at time: TimeInterval) -> Bool {
            presentationMatches(CGRect(origin: .zero, size: size),
                recent: recentPresentationSizes(at: time, frames: history, initial: old))
        }
        // A long idle hold is valid, but a replaced size expires after100 ms.
        return matches(old, at: 9.9) && !matches(new, at: 9.9)
            && matches(old, at: 10.02) && matches(new, at: 10.02)
            && !matches(old, at: 10.101) && matches(new, at: 10.101)
            && !matches(CGSize(width: 999, height: 999), at: 10.02)
    }
    private struct ViewUpdateAge {
        let acknowledgedApplyAt: TimeInterval
        let replacedAt: TimeInterval?
        let seconds: TimeInterval
        let rawSeconds: TimeInterval
    }
    /// Age begins when the acknowledged state is first replaced, not when an
    /// unchanged idle state was acknowledged. Further requests cannot reset it.
    /// This observes SwiftUI view updates, not compositor presentation or paint.
    private func viewUpdateAge(at now: TimeInterval, renderedAt: TimeInterval,
        rendered: Double, requested: Double,
        history: [(time: TimeInterval, progress: Double)]) -> ViewUpdateAge? {
        guard now.isFinite, renderedAt.isFinite, renderedAt <= now,
            rendered.isFinite, requested.isFinite, (0...1).contains(rendered), (0...1).contains(requested),
            !history.isEmpty,
            history.allSatisfy({ $0.time.isFinite && $0.progress.isFinite && (0...1).contains($0.progress) }),
            zip(history, history.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return nil }
        let available = history.filter { $0.time <= now }
        guard let latest = available.last, abs(latest.progress - requested) < 1e-12,
            let acknowledged = available.lastIndex(where: {
                $0.time <= renderedAt && abs($0.progress - rendered) < 1e-12
            }) else { return nil }
        let replacement = available.dropFirst(acknowledged + 1).first {
            abs($0.progress - rendered) > 0.00001
        }?.time
        let mismatch = abs(requested - rendered) > 0.00001
        guard !mismatch || replacement != nil else { return nil }
        return ViewUpdateAge(acknowledgedApplyAt: available[acknowledged].time, replacedAt: replacement,
            seconds: mismatch ? now - (replacement ?? now) : 0, rawSeconds: mismatch ? now - renderedAt : 0)
    }
    private func verifyViewUpdateHistoryControls() -> Bool {
        let history: [(time: TimeInterval, progress: Double)] = [
            (1, 0), (10, 0.1), (10.04, 0.2), (10.08, 0.3), (10.12, 0.2), (10.16, 0.1)]
        func age(_ now: TimeInterval, _ rendered: Double, _ acknowledged: TimeInterval, _ requested: Double,
            _ entries: [(time: TimeInterval, progress: Double)] = []) -> ViewUpdateAge? {
            viewUpdateAge(at: now, renderedAt: acknowledged, rendered: rendered, requested: requested,
                history: entries.isEmpty ? history : entries)
        }
        let idle = age(9, 0, 1.01, 0)
        let firstReplacement = age(10.02, 0, 1.01, 0.1)
        let backlog = age(10.121, 0, 1.01, 0.2)
        let moving = age(10.161, 0.1, 10.01, 0.1)
        let staleMoving = age(10.161, 0.1, 10.01, 0.4, history + [(10.16, 0.4)])
        let reversal = age(10.17, 0.2, 10.125, 0.1)
        let unacknowledgedReversal = age(10.13, 0.2, 10.05, 0.2)
        // Repeated requests preserve the first outstanding replacement. A newly
        // acknowledged reversal starts a new budget; a matching final state has no lag.
        return idle?.seconds == 0
            && firstReplacement.map { abs($0.seconds - 0.02) < 1e-10 && $0.rawSeconds > 9 } == true
            && backlog.map { $0.seconds > 0.12 && $0.replacedAt == 10 } == true
            && moving?.seconds == 0
            && staleMoving.map { $0.seconds > 0.12 && $0.replacedAt == 10.04 } == true
            && reversal.map { abs($0.seconds - 0.01) < 1e-10 && $0.acknowledgedApplyAt == 10.12 } == true
            && unacknowledgedReversal?.seconds == 0
            && age(10.02, 0.2, 10.01, 0.1) == nil // Future matching apply cannot acknowledge a view.
            && age(10.02, 0, 10.03, 0.1) == nil // Future acknowledgement.
            && age(10.02, 0.7, 1.01, 0.1) == nil // Unmatched state.
            && age(10.02, 0, 1.01, 0.9) == nil // Untracked current request.
            && age(10.02, 0, 1.01, 0.1, [(1, 0), (10, 0.1), (9, 0.2)]) == nil
            && age(10.02, 0, 1.01, 0.1, [(1, 0), (Double.nan, 0.1)]) == nil
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    private func summarize() {
        let profile = profiles[profileIndex]
        if let pacing { pacingResults.append(pacing); self.pacing = nil }
        var pacingValid = pacingResults.count == 3
        for value in pacingResults {
            let valid = value.at95.map { $0 > 0.05 && $0 < 1.2 } == true
                && value.at99.map { $0 >= (value.at95 ?? .infinity) && $0 < 1.4 } == true
            pacingValid = pacingValid && valid
            SmokeDiagnostics.mark("motion reference-paced profile=\(profile) phase=\(value.name) at95Seconds=\(String(describing: value.at95)) at99Seconds=\(String(describing: value.at99)) valid=\(valid) nominalReferenceSeconds=0.4 exactReferenceSpring=false")
        }
        let durations = samples.map(\.applyDuration)
        let gaps = zip(samples, samples.dropFirst()).compactMap { a, b -> Double? in
            a.generation == b.generation ? b.observed - a.observed : nil
        }
        let maxGap = gaps.max() ?? .infinity, p95Gap = percentile(gaps, 0.95), p95Apply = percentile(durations, 0.95)
        let requestHistory = [(time: initialApplyTime, progress: 0.0)] + samples.map {
            (time: $0.observed, progress: $0.progress)
        }
        let viewAges = probes.map { probe in
            viewUpdateAge(at: probe.observed, renderedAt: probe.renderedAt,
                rendered: probe.renderedProgress, requested: probe.requestedProgress, history: requestHistory)
        }
        let historyValid = viewAges.allSatisfy { $0 != nil }
        let maxRenderLag = historyValid ? (viewAges.compactMap { $0?.seconds }.max() ?? 0) : .infinity
        let maxRawAge = viewAges.compactMap { $0?.rawSeconds }.max() ?? .infinity
        let worstCorrected = viewAges.indices.max { (viewAges[$0]?.seconds ?? .infinity) < (viewAges[$1]?.seconds ?? .infinity) }
        let worstRaw = viewAges.indices.max { (viewAges[$0]?.rawSeconds ?? .infinity) < (viewAges[$1]?.rawSeconds ?? .infinity) }
        for index in probes.indices where viewAges[index] == nil || index == worstCorrected || index == worstRaw {
            let probe = probes[index], age = viewAges[index]
            SmokeDiagnostics.mark("motion view-age profile=\(profile) probe=\(index) observed=\(probe.observed) requested=\(probe.requestedProgress) rendered=\(probe.renderedProgress) acknowledgedAt=\(probe.renderedAt) matchedApplyAt=\(String(describing: age?.acknowledgedApplyAt)) firstReplacementAt=\(String(describing: age?.replacedAt)) rawAgeSeconds=\(String(describing: age?.rawSeconds)) replacementAgeSeconds=\(String(describing: age?.seconds)) historyValid=\(age != nil)")
            if let age {
                let relevant = requestHistory.filter { $0.time >= age.acknowledgedApplyAt && $0.time <= probe.observed }
                SmokeDiagnostics.mark("motion view-age request-history profile=\(profile) probe=\(index) states=\(relevant)")
            }
        }
        let presentationProbes = probes.filter { $0.layerPresentation != nil }
        let activePresentationCount = presentationProbes.filter { $0.running }.count
        var presentationsValid = true
        for probe in presentationProbes {
            guard let bounds = probe.layerPresentation else { continue }
            // A held frame does not grow stale while idle. Its replacement starts
            // the <=100 ms presentation allowance, including the first moving frame.
            let recent = recentPresentationSizes(at: probe.observed,
                frames: samples.map { (time: $0.observed, size: $0.frame.size) }, initial: geometry.frame(progress: 0).size)
            let valid = presentationMatches(bounds, recent: recent)
            if !valid {
                SmokeDiagnostics.mark("motion presentation rejected profile=\(profile) time=\(probe.observed) current=\(probe.frame.size) presentation=\(bounds) recent=\(recent)")
                presentationsValid = false
            }
        }
        let native = samples.allSatisfy { sample in
            let expected = expectedMotionGeometry.frame(progress: sample.progress)
            return sample.visible && sample.nonKey && sample.frame == expected
                && sample.contentBounds.origin == .zero && sample.contentBounds.size == sample.frame.size
                && sample.progress.isFinite && sample.velocity.isFinite
        }
        let source = samples.first?.source ?? "missing"
        let expectedSource: String
        if #available(macOS 14.0, *), profile == .adaptive { expectedSource = "view-display-link" }
        else { expectedSource = profile == .synchronousBaseline ? "timer-60hz" : "dispatch-60hz" }
        // Baseline is observational. The new path and13 fallback must meet bounded
        // callback and view-update limits under the same synthetic load.
        let cadence = maxGap <= 0.12 && p95Gap <= 0.05 && p95Apply <= 0.02 && maxRenderLag <= 0.12
        let activePaints = paints.filter { $0.active }
        let paintMatches = paints.allSatisfy { entry in
            let receipt = entry.receipt, p = receipt.frame.progress
            let expected = IslandContour(rect: expectedMotionGeometry.contourRect(progress: p), progress: p,
                cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height)
            return receipt.actualViewport == receipt.frame.viewport
                && receipt.frame.viewport == expectedMotionGeometry.frame(progress: p).size
                && receipt.bodyBounds == contourPath(expected, inset: 0, closed: true).boundingRect
                && receipt.railBounds == contourPath(expected, inset: 2, closed: false).boundingRect
        }
        // A real callback writes both paths together. Distinct active samples must
        // cover opening and closing, rather than reusing a settled idle receipt.
        let progressDeltas = zip(activePaints, activePaints.dropFirst()).map { $1.receipt.frame.progress - $0.receipt.frame.progress }
        let openingPaints = progressDeltas.filter { $0 > 0.0001 }.count
        let closingPaints = progressDeltas.filter { $0 < -0.0001 }.count
        let coherentPaint = activePaints.count >= 20 && openingPaints >= 5 && closingPaints >= 5 && paintMatches
        SmokeDiagnostics.mark("motion synchronous-paint profile=\(profile) callbacks=\(paints.count) active=\(activePaints.count) opening=\(openingPaints) closing=\(closingPaints) sameFramePaths=\(paintMatches) valid=\(coherentPaint) scanout=false")
        let valid = pacingValid && coherentPaint && historyValid && samples.count >= 30 && probes.count >= 30 && presentationProbes.count >= 20 && activePresentationCount >= 20
            && presentationsValid && native && source == expectedSource
            && (profile == .synchronousBaseline || cadence)
        passed = valid && passed
        summaries.append((profile.rawValue, p95Apply, p95Gap))
        SmokeDiagnostics.mark("motion summary profile=\(profile) source=\(source) callbacks=\(samples.count) normalRunLoopProbes=\(probes.count) loadUpdates=\(loadCount) callbackMaxSeconds=\(maxGap) callbackP95Seconds=\(p95Gap) applyP95Seconds=\(p95Apply) maxViewUpdateLagSeconds=\(maxRenderLag) maxRawViewAgeSeconds=\(maxRawAge) viewHistoryValid=\(historyValid) presentationSamples=\(presentationProbes.count) activePresentationSamples=\(activePresentationCount) presentationBoundsValid=\(presentationsValid) native=\(native) cadence=\(cadence) valid=\(valid)")
        for (index, sample) in samples.enumerated() where index % 12 == 0 || index == samples.count - 1 {
            SmokeDiagnostics.mark("motion sample profile=\(profile) index=\(index) observed=\(sample.observed) scheduled=\(sample.scheduled) generation=\(sample.generation) progress=\(sample.progress) velocity=\(sample.velocity) applySeconds=\(sample.applyDuration) frame=\(sample.frame) content=\(sample.contentBounds) previousViewUpdatedViewport=\(sample.viewport)")
        }
        for (index, probe) in probes.enumerated() where index % 20 == 0 || index == probes.count - 1 {
            SmokeDiagnostics.mark("motion normal-runloop probe profile=\(profile) time=\(probe.observed) requested=\(probe.requestedProgress) viewUpdated=\(probe.renderedProgress) frame=\(probe.frame) viewport=\(probe.viewport) layerPresentation=\(String(describing: probe.layerPresentation))")
        }
    }
    private func finish(_ result: Bool) {
        stop()
        print(result ? "MOTION_OK: native frame sources, continuous reversal, view/presentation bounds and cleanup passed" : "MOTION_FAILED: native motion evidence failed")
        completion(result)
    }
    func stop() { timer?.invalidate(); timer = nil; controller?.stop() }
}
#endif
