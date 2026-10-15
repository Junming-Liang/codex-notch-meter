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
    private let completion: (Bool) -> Void
    private let profiles: [IslandMotionProfile] = [.synchronousBaseline, .adaptive, .timerFallback]
    private var profileIndex = 0
    private var controller: IslandPanelController?
    private var timer: Timer?
    private var samples: [IslandMotionSample] = []
    private var probes: [IslandMotionProbe] = []
    private var summaries: [(String, Double, Double)] = []
    private var phase = 0
    private var phaseStarted = CACurrentMediaTime()
    private var lastLoad = CACurrentMediaTime()
    private var lastColorLoad = CACurrentMediaTime()
    private var loadCount = 0
    private var passed = true
    private var heldPointer: CGPoint?
    private weak var initialKey: NSWindow?
    init(model: MeterModel, geometry: IslandGeometry, completion: @escaping (Bool) -> Void) {
        self.model = model; self.geometry = geometry; self.completion = completion
        super.init()
    }
    func start() {
        guard model.demo, CommandLine.arguments.contains("--motion-test") else { finish(false); return }
        model.theme = .rainbow
        initialKey = NSApp.keyWindow
        startProfile()
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(check(_:)), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func startProfile() {
        controller?.stop(); samples = []; probes = []; phase = 0; phaseStarted = CACurrentMediaTime(); loadCount = 0; heldPointer = nil
        let profile = profiles[profileIndex]
        model.setMotionFixture(remaining: 72)
        lastLoad = CACurrentMediaTime(); lastColorLoad = lastLoad
        controller = IslandPanelController(model: model, geometry: geometry, startPolling: false, reducedMotionOverride: false,
            motionProfile: profile, motionSample: { [weak self] sample in
                guard let self else { return }
                if self.samples.count < 1500 { self.samples.append(sample) } else { self.passed = false }
            }, hovered: {}, refresh: {}, settings: {}, quit: {})
        SmokeDiagnostics.mark("motion profile=\(profile.rawValue) baselineScope=old-drawing-layout-strategy/shared-new-spring buckets=4 windows=8 actualBacking=\(controller?.panel.backingScaleFactor ?? 0)")
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
            next(4, now: now)
        case 4 where island.smokeProgress == 1 && !island.smokeMotionRunning:
            heldPointer = nil; next(5, now: now)
        case 5 where elapsed >= 0.10:
            let expanded = island.verifyExpandedLayout(includePixels: false) && island.verifySmokeClickRouting()
            let viewUpdated = probe.viewport == probe.frame.size && probe.renderedProgress == 1
            passed = expanded && viewUpdated && passed
            SmokeDiagnostics.mark("motion expanded view-update profile=\(profiles[profileIndex]) viewport=\(probe.viewport) content=\(probe.contentBounds) presentation=\(String(describing: probe.layerPresentation)) viewUpdated=\(viewUpdated) quit=\(expanded)")
            island.collapse(); passed = island.verifyNonadvancingFramesAreInert() && passed
            next(6, now: now)
        case 6 where island.smokeProgress == 0 && !island.smokeMotionRunning:
            next(7, now: now)
        case 7 where elapsed >= 0.10:
            let viewUpdated = probe.viewport == geometry.frame(progress: 0).size && probe.renderedProgress == 0
            passed = viewUpdated && passed
            SmokeDiagnostics.mark("motion recollapse view-update profile=\(profiles[profileIndex]) viewUpdated=\(viewUpdated) frame=\(probe.frame) viewport=\(probe.viewport)")
            island.beginSmokeExpansion(); next(8, now: now)
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
    private func edgePoint(inside: Bool) -> CGPoint? {
        guard let island = controller else { return nil }
        let p = island.smokeProgress, frame = geometry.frame(progress: p), contour = geometry.contourRect(progress: p)
        return CGPoint(x: frame.minX + contour.maxX + (inside ? -0.25 : 0.25),
            y: frame.maxY - contour.midY)
    }
    private func crossEdge(inside: Bool, now: TimeInterval) {
        guard let island = controller, let point = edgePoint(inside: inside) else { passed = false; return }
        island.smokePointer(at: point, now: now)
        SmokeDiagnostics.mark("motion boundary profile=\(profiles[profileIndex]) point=\(point) inside=\(inside) progress=\(island.smokeProgress) targetExpanded=\(island.smokeTargetExpanded)")
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    private func summarize() {
        let profile = profiles[profileIndex]
        let durations = samples.map(\.applyDuration)
        let gaps = zip(samples, samples.dropFirst()).compactMap { a, b -> Double? in
            a.generation == b.generation ? b.observed - a.observed : nil
        }
        let maxGap = gaps.max() ?? .infinity, p95Gap = percentile(gaps, 0.95), p95Apply = percentile(durations, 0.95)
        let mismatch = probes.filter { abs($0.requestedProgress - $0.renderedProgress) > 0.00001 }
        let maxRenderLag = mismatch.map { max(0, $0.observed - $0.renderedAt) }.max() ?? 0
        let presentationProbes = probes.filter { $0.layerPresentation != nil }
        let activePresentationCount = presentationProbes.filter { $0.running }.count
        let presentationsValid = presentationProbes.allSatisfy { probe in
            guard let bounds = probe.layerPresentation, bounds.origin == .zero else { return false }
            let recent = [probe.frame.size] + samples.filter {
                $0.observed <= probe.observed && probe.observed - $0.observed <= 0.1
            }.map { $0.frame.size }
            return recent.contains { abs($0.width - bounds.width) < 0.01 && abs($0.height - bounds.height) < 0.01 }
        }
        let native = samples.allSatisfy { sample in
            let expected = geometry.frame(progress: sample.progress)
            return sample.visible && sample.nonKey && sample.frame == expected
                && sample.contentBounds.origin == .zero && sample.contentBounds.size == sample.frame.size
                && sample.progress.isFinite && sample.velocity.isFinite
        }
        let source = samples.first?.source ?? "missing"
        let expectedSource: String
        if #available(macOS 14.0, *), profile == .adaptive { expectedSource = "view-display-link" }
        else { expectedSource = "timer-60hz" }
        // Baseline is observational. The new path and13 fallback must meet bounded
        // callback and view-update limits under the same synthetic load.
        let cadence = maxGap <= 0.12 && p95Gap <= 0.05 && p95Apply <= 0.02 && maxRenderLag <= 0.12
        let valid = samples.count >= 30 && probes.count >= 30 && presentationProbes.count >= 20 && activePresentationCount >= 20
            && presentationsValid && native && source == expectedSource
            && (profile == .synchronousBaseline || cadence)
        passed = valid && passed
        summaries.append((profile.rawValue, p95Apply, p95Gap))
        SmokeDiagnostics.mark("motion summary profile=\(profile) source=\(source) callbacks=\(samples.count) normalRunLoopProbes=\(probes.count) loadUpdates=\(loadCount) callbackMaxSeconds=\(maxGap) callbackP95Seconds=\(p95Gap) applyP95Seconds=\(p95Apply) maxViewUpdateLagSeconds=\(maxRenderLag) presentationSamples=\(presentationProbes.count) activePresentationSamples=\(activePresentationCount) presentationBoundsValid=\(presentationsValid) native=\(native) cadence=\(cadence) valid=\(valid)")
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
