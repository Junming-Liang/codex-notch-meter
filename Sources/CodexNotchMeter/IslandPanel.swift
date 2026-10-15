#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import NotchCore

final class TopEdgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class IslandPresentation: ObservableObject {
    @Published var progress: Double = 0
    @Published var geometry: IslandGeometry
    @Published var notice: RefreshNotice?
    @Published var showingDetails = true
    init(geometry: IslandGeometry) { self.geometry = geometry }
}

struct IslandSilhouette: Shape {
    let progress: Double
    var drawingRect: CGRect? = nil
    var cornerAdjustment: Double = 0
    var referenceDepth: CGFloat = 32
    func path(in viewport: CGRect) -> Path {
        contourPath(IslandContour(rect: drawingRect ?? viewport, progress: progress,
            cornerAdjustment: cornerAdjustment, referenceDepth: referenceDepth), inset: 0, closed: true)
    }
}

func contourPath(_ contour: IslandContour, inset: CGFloat, closed: Bool) -> Path {
    var path = Path()
    for command in contour.commands(inset: inset) {
        switch command {
        case .move(let point): path.move(to: point)
        case .line(let point): path.addLine(to: point)
        case .arc(let center, let radius, let start, let end, let clockwise):
            path.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: clockwise)
        }
    }
    if closed { path.closeSubpath() }
    return path
}

private struct IslandRenderObservation: Equatable {
    let progress: Double
    let size: CGSize
}

@MainActor
private struct IslandRootView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var presentation: IslandPresentation
    var geometry: IslandGeometry { presentation.geometry }
    let motionProfile: IslandMotionProfile
    let refresh: () -> Void
    let settings: () -> Void
    let quit: () -> Void
    let quitFrameChanged: (CGRect) -> Void
    let viewportChanged: (CGSize) -> Void
    let rendered: (Double, CGSize) -> Void
    var body: some View {
        let p = presentation.progress
        let promoting = presentation.notice != nil
        let detailReveal = promoting ? IslandReveal.smooth((p - geometry.updateProgress) / (1 - geometry.updateProgress)) : IslandReveal.details(p)
        GeometryReader { viewport in
            Color.clear
                .overlay { IslandSilhouette(progress: p, drawingRect: geometry.contourRect(progress: p), cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height).fill(.black.opacity(motionProfile.forcesLayout ? min(1, p * 3) : IslandReveal.surface(p))) }
                .overlay(alignment: .topLeading) {
                    RailView(model: model, drawingRect: geometry.contourRect(progress: p), progress: p, cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height, hovered: { _ in })
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .opacity(motionProfile.forcesLayout ? max(0, 1 - p * 4) : IslandReveal.rail(p))
                    .accessibilityHidden(p > 0.1)
                }
                .overlay(alignment: .topLeading) {
                    // Opacity-zero fixed-height content MUST NOT size the collapsed root.
                    if motionProfile.prewarmsDetails || p > 0 {
                        CompactDetailView(model: model, height: geometry.contentHeight, quitFrameChanged: quitFrameChanged, refresh: refresh, settings: settings, quit: quit)
                            .frame(width: 304)
                            .offset(x: geometry.frame(progress: 1).minX + geometry.contourRect(progress: 1).midX - geometry.frame(progress: p).minX - 152,
                                    y: geometry.notch.height + 8 + (motionProfile.forcesLayout ? 0 : (1 - detailReveal) * 6))
                            .opacity(presentation.showingDetails ? (motionProfile.forcesLayout ? min(1, max(0, (p - 0.35) / 0.5)) : detailReveal) : 0)
                            .allowsHitTesting(p == 1 && presentation.showingDetails)
                            .accessibilityHidden(p < 1)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let notice = presentation.notice {
                        RefreshNoticeView(notice: notice)
                            .frame(width: 304, height: 62)
                            .offset(x: geometry.frame(progress: 1).minX + geometry.contourRect(progress: 1).midX - geometry.frame(progress: p).minX - 152,
                                    y: geometry.notch.height + 8)
                            .opacity(IslandReveal.smooth(p / geometry.updateProgress) * (presentation.showingDetails ? 1 - detailReveal : 1))
                            .allowsHitTesting(false).accessibilityHidden(p == 0)
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .clipShape(IslandSilhouette(progress: p, drawingRect: geometry.contourRect(progress: p), cornerAdjustment: geometry.shapeCalibration.corner, referenceDepth: geometry.notch.height))
                .onAppear { viewportChanged(viewport.size); rendered(p, viewport.size) }
                // A single coherent observation avoids a resize callback overwriting
                // the new progress with the previous body's captured progress.
                .onChange(of: IslandRenderObservation(progress: p, size: viewport.size)) { observation in
                    viewportChanged(observation.size); rendered(observation.progress, observation.size)
                }
            }
        .ignoresSafeArea(.all)
        // Native panel frame and this shape share one spring; no implicit size animation.
        .transaction { $0.animation = nil }
    }
}

/// Synthetic-only retarget observation; no account data or production logging.
struct IslandMotionRetarget {
    let scheduledTime: TimeInterval
    let eventTime: TimeInterval
    let consumedElapsed: TimeInterval
    let before: IslandMotion
    let integrated: IslandMotion
    let previousTarget: Bool
    let nextTarget: Bool
}

struct IslandCloseReceipt {
    let requestedAt: TimeInterval
    let acknowledgedAt: TimeInterval?
    let completedAt: TimeInterval?
    let finalDisplayDuration: TimeInterval
    let renderedAt: TimeInterval?
    let outcome: ClosePresentationDrain.Outcome
}

@MainActor
final class IslandPanelController: NSObject {
    private let model: MeterModel
    var geometry: IslandGeometry { presentation.geometry }
    let panel: TopEdgePanel
    private let presentation: IslandPresentation
    private var pendingGeometry: IslandGeometry?
    private var hover = IslandHoverState()
    private var motion = IslandMotion()
    private var pointerTimer: Timer?
    private var motionFrames: IslandFrameSource?
    private var frameGeneration = 0
    private var motionTargetExpanded = false
    private var motionTargetValue: Double = 0
    private var noticeExpiry: Timer?
    private var noticeTargetActive = false
    private var lastMotionTime = CACurrentMediaTime()
    private let motionProfile: IslandMotionProfile
    private let motionSample: ((IslandMotionSample) -> Void)?
    private var closeDrain = ClosePresentationDrain()
    private var closeGeneration: UInt64?
    private var closeDeadline: Timer?
    private let drainsClosePresentation: Bool
    private(set) var closeReceipt: IslandCloseReceipt?
    private var lastRetarget: IslandMotionRetarget?
    private let reducedMotionOverride: Bool?
    private var reducedMotion: Bool { reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var placementIsValid = true
    private var stopped = false
    private var quitFrame: CGRect = .zero
    private(set) var renderedViewport: CGSize = .zero
    private var renderedProgress: Double = 0
    private var renderedAt = CACurrentMediaTime()
    private let hovered: () -> Void
    private let activityChanged: () -> Void

    init(model: MeterModel, geometry: IslandGeometry, startPolling: Bool = true, reducedMotionOverride: Bool? = nil,
         motionProfile: IslandMotionProfile = .adaptive, drainsClosePresentation: Bool = true, motionSample: ((IslandMotionSample) -> Void)? = nil,
         activityChanged: @escaping () -> Void = {}, hovered: @escaping () -> Void, refresh: @escaping () -> Void,
         settings: @escaping () -> Void, quit: @escaping () -> Void) {
        let motionDiagnostic = model.demo && (CommandLine.arguments.contains("--motion-test") || (CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test")))
        self.motionProfile = motionDiagnostic ? motionProfile : .adaptive
        self.drainsClosePresentation = model.demo && (CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test")) ? drainsClosePresentation : true
        self.motionSample = motionSample
        self.model = model
        self.presentation = IslandPresentation(geometry: geometry); self.hovered = hovered; self.activityChanged = activityChanged; self.reducedMotionOverride = reducedMotionOverride
        panel = TopEdgePanel(contentRect: geometry.frame(progress: 0), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.animationBehavior = .none; panel.ignoresMouseEvents = true
        let hosting = IslandHostingView(rootView: IslandRootView(model: model, presentation: presentation,
            motionProfile: self.motionProfile, refresh: refresh, settings: settings, quit: quit,
            quitFrameChanged: { [weak self] in self?.quitFrame = $0 },
            viewportChanged: { [weak self] in self?.renderedViewport = $0 },
            rendered: { [weak self] progress, size in
                self?.renderedProgress = progress; self?.renderedViewport = size; self?.renderedAt = CACurrentMediaTime()
            }))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.sizingOptions = []
        if #available(macOS 14.0, *) { hosting.safeAreaRegions = [] }
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        apply(progress: 0)
        panel.orderFrontRegardless()
        apply(progress: 0)
        if startPolling {
            let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(pollPointer(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common); pointerTimer = timer
        }
    }
    func updateGeometry(_ value: IslandGeometry) {
        guard !stopped, geometry.hasSameAnchor(as: value) else { return }
        // Freeze the content-fit endpoint through an open interaction. New data remains
        // scrollable now; its smaller/larger endpoint is adopted only at the next idle.
        pendingGeometry = value
        if motion.progress == 0 && !motionTargetExpanded && !closeDrain.isPending { apply(progress: 0) }
    }
    private func apply(progress: Double) {
        guard !stopped else { return }
        if progress == 0, let pendingGeometry {
            presentation.geometry = pendingGeometry; self.pendingGeometry = nil
        }
        let hadDetails = displaysColoredDetails
        if (progress == 0 && !noticeTargetActive) || (progress == 1 && hover.isExpanded) {
            if presentation.notice != nil { presentation.notice = nil }
            if !presentation.showingDetails { presentation.showingDetails = true }
        }
        if presentation.progress != progress { presentation.progress = progress }
        if hadDetails != displaysColoredDetails { activityChanged() }
        let expected = geometry.frame(progress: progress)
        if panel.frame != expected { panel.setFrame(expected, display: motionProfile.forcesLayout) }
        if motionProfile.forcesLayout { panel.contentView?.layoutSubtreeIfNeeded() }
        if abs(panel.frame.maxY - geometry.screen.maxY) > 0.5 || abs(panel.frame.width - expected.width) > 0.5 {
            placementIsValid = false
            panel.orderOut(nil)
        }
    }
    func setContourTestProgress(_ progress: Double) {
        guard CommandLine.arguments.contains("--contour-test") || CommandLine.arguments.contains("--alignment-test") || (CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test")) else { return }
        apply(progress: progress)
    }
    @objc private func pollPointer(_ timer: Timer) {
        guard !stopped, timer === pointerTimer, placementIsValid else { return }
        updatePointer(NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime)
    }
    private func updatePointer(_ point: CGPoint, now: TimeInterval) {
        guard !stopped else { return }
        let before = hover.isExpanded
        hover.update(inside: geometry.hoverContains(point, progress: motion.progress), now: now,
            resumeExpanded: (presentation.notice != nil && motion.progress > 0) || ((motion.progress > 0 || closeDrain.isPending) && !motionTargetExpanded))
        if hover.isExpanded != before {
            if hover.isExpanded { hovered(); noticeExpiry?.invalidate(); noticeExpiry = nil; noticeTargetActive = false; presentation.showingDetails = true }
            else { noticeTargetActive = false }
            startMotion()
        }
        updateClickRouting(point)
    }
    private func updateClickRouting(_ point: CGPoint) {
        panel.ignoresMouseEvents = !(hover.isExpanded && motion.isSettled && motion.progress == 1 && geometry.interactiveContains(point))
    }
    private func startMotion() {
        guard !stopped else { return }
        cancelCloseDrain()
        let now = CACurrentMediaTime()
        let previousTime = lastMotionTime, previousMotion = motion, previousTarget = motionTargetExpanded
        let elapsed = motionFrames != nil ? max(0, now - lastMotionTime) : 0
        // Consume elapsed time under the previous target before a reversal. A display
        // link may already have projected up to its next frame, so never rewind time.
        if motionFrames != nil, now > lastMotionTime {
            motion.advance(target: motionTargetValue, elapsed: now - lastMotionTime, reduceMotion: reducedMotion)
            lastMotionTime = now
        }
        let integrated = motion
        motionTargetValue = hover.isExpanded ? 1 : (noticeTargetActive ? geometry.updateProgress : 0)
        motionTargetExpanded = motionTargetValue > 0
        if motionSample != nil {
            lastRetarget = IslandMotionRetarget(scheduledTime: previousTime, eventTime: now,
                consumedElapsed: elapsed, before: previousMotion, integrated: integrated,
                previousTarget: previousTarget, nextTarget: motionTargetExpanded)
        }
        if reducedMotion {
            stopMotionFrames()
            motion.advance(target: motionTargetValue, elapsed: 0, reduceMotion: true)
            apply(progress: motion.progress); updateClickRouting(NSEvent.mouseLocation); scheduleNoticeExpiryIfReady()
            return
        }
        guard motionFrames == nil else { return }
        lastMotionTime = now
        frameGeneration += 1
        let generation = frameGeneration
        let callback: (TimeInterval) -> Void = { [weak self] time in
            guard let self, !self.stopped, self.frameGeneration == generation, self.motionFrames != nil else { return }
            self.advanceFrame(to: time)
        }
        if motionProfile == .synchronousBaseline { motionFrames = TimerIslandFrames(callback: callback) }
        else if #available(macOS 14.0, *), motionProfile == .adaptive, let view = panel.contentView {
            motionFrames = DisplayIslandFrames(view: view, callback: callback)
        } else { motionFrames = DispatchIslandFrames(callback: callback) }
    }
    private func advanceFrame(to time: TimeInterval) {
        guard !stopped, let source = motionFrames, time.isFinite, time > lastMotionTime else { return }
        let now = CACurrentMediaTime(), elapsed = max(0, time - lastMotionTime)
        lastMotionTime = max(lastMotionTime, time)
        let previousProgress = motion.progress
        motion.advance(target: motionTargetValue, elapsed: elapsed, reduceMotion: reducedMotion)
        let began = CACurrentMediaTime()
        var startedCloseDrain = false
        if drainsClosePresentation, let generation = closeDrain.begin(previousProgress: previousProgress,
            progress: motion.progress, expanded: motionTargetExpanded, reduceMotion: reducedMotion, now: began) {
            startedCloseDrain = true
            closeGeneration = generation
            closeReceipt = IslandCloseReceipt(requestedAt: began, acknowledgedAt: nil, completedAt: nil, finalDisplayDuration: 0, renderedAt: nil, outcome: .pending)
            let deadline = Timer(timeInterval: closeDrain.timeout, target: self,
                selector: #selector(closeDeadlineReached(_:)), userInfo: generation, repeats: false)
            closeDeadline = deadline; RunLoop.main.add(deadline, forMode: .common)
        }
        apply(progress: motion.progress); updateClickRouting(NSEvent.mouseLocation)
        let duration = CACurrentMediaTime() - began
        motionSample?(IslandMotionSample(observed: now, scheduled: time, generation: frameGeneration, applyDuration: duration,
            progress: motion.progress, velocity: motion.velocity, expanded: motionTargetExpanded,
            frame: panel.frame, contentBounds: panel.contentView?.bounds ?? .zero,
            viewport: renderedViewport, visible: panel.isVisible, nonKey: !panel.isKeyWindow && !panel.canBecomeKey,
            source: source.kind))
        // A callback may retarget through a diagnostic observer; never retire its new motion.
        guard !stopped, motion.isSettled(at: motionTargetValue) else { return }
        scheduleNoticeExpiryIfReady()
        if startedCloseDrain { return } // Never acknowledge within the requesting callback.
        if closeDrain.isPending { observeClosePresentation(at: CACurrentMediaTime()) }
        else { stopMotionFrames() }
    }
    private func observeClosePresentation(at time: TimeInterval) {
        guard !stopped, !motionTargetExpanded, let generation = closeGeneration else { return }
        let expected = geometry.frame(progress: 0)
        let matches = panel.frame == expected && renderedViewport == expected.size
            && panel.contentView?.bounds == CGRect(origin: .zero, size: expected.size)
        let outcome = closeDrain.poll(generation: generation, now: time, renderedAt: renderedAt,
            renderedProgress: renderedProgress, viewportMatches: matches)
        guard outcome == .ready || outcome == .timedOut else { return }
        let request = closeReceipt?.requestedAt, acknowledgedRender = renderedAt
        // One final display opportunity after a normal-run-loop view acknowledgement.
        // This is not a compositor/scanout guarantee and never forces per-frame layout.
        let displayStarted = CACurrentMediaTime()
        if outcome == .ready { panel.contentView?.displayIfNeeded() }
        let displayDuration = outcome == .ready ? CACurrentMediaTime() - displayStarted : 0
        stopMotionFrames()
        if let request {
            closeReceipt = IslandCloseReceipt(requestedAt: request,
                acknowledgedAt: outcome == .ready ? time : nil, completedAt: CACurrentMediaTime(),
                finalDisplayDuration: displayDuration, renderedAt: acknowledgedRender, outcome: outcome)
        }
    }
    @objc private func closeDeadlineReached(_ sender: Timer) {
        guard sender === closeDeadline, !stopped, closeDrain.isPending else { return }
        observeClosePresentation(at: CACurrentMediaTime())
    }
    private func cancelCloseDrain() {
        closeDrain.cancel(); closeGeneration = nil
        closeDeadline?.invalidate(); closeDeadline = nil
    }
    private func stopMotionFrames() {
        cancelCloseDrain()
        frameGeneration += 1
        motionFrames?.stop(); motionFrames = nil
    }
    var isInteracting: Bool { hover.isExpanded }
    @discardableResult func showRefreshNotice(_ notice: RefreshNotice) -> Bool {
        guard !stopped, model.refreshNoticesEnabled, !hover.isExpanded, placementIsValid else { return false }
        noticeExpiry?.invalidate(); noticeExpiry = nil
        presentation.notice = notice; presentation.showingDetails = false; noticeTargetActive = true
        startMotion(); panel.ignoresMouseEvents = true
        return true
    }
    func dismissRefreshNotice() {
        guard presentation.notice != nil else { return }
        noticeExpiry?.invalidate(); noticeExpiry = nil; noticeTargetActive = false
        if !hover.isExpanded { startMotion() }
    }
    private func scheduleNoticeExpiryIfReady() {
        guard noticeTargetActive, presentation.notice != nil, !hover.isExpanded, noticeExpiry == nil,
              motion.isSettled(at: geometry.updateProgress) else { return }
        let timer = Timer(timeInterval: presentation.notice?.holdDuration ?? 2, target: self, selector: #selector(expireNotice(_:)), userInfo: nil, repeats: false)
        noticeExpiry = timer; RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func expireNotice(_ sender: Timer) {
        guard !stopped, sender === noticeExpiry else { return }
        noticeExpiry = nil
        guard !hover.isExpanded else { return }
        // Retain the text during the closing fade; a separate flag chooses the idle target.
        noticeTargetActive = false
        startMotion()
    }
    func collapse() {
        guard !stopped else { return }
        noticeExpiry?.invalidate(); noticeExpiry = nil; noticeTargetActive = false
        hover.reset(); panel.ignoresMouseEvents = true; startMotion()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        noticeExpiry?.invalidate(); noticeExpiry = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        stopMotionFrames()
        panel.ignoresMouseEvents = true; panel.close()
    }
    func verifyNonadvancingFramesAreInert() -> Bool {
        guard CommandLine.arguments.contains("--motion-test"), motionFrames != nil else { return false }
        let before = (motion.progress, motion.velocity, panel.frame)
        advanceFrame(to: lastMotionTime); advanceFrame(to: lastMotionTime - 1)
        return motionFrames != nil && motion.progress == before.0 && motion.velocity == before.1 && panel.frame == before.2
    }
    /// The explicit synthetic harness invokes a real retired source and stopped actions.
    func verifyRetiredMotionIsInert() -> Bool {
        guard CommandLine.arguments.contains("--motion-test") || (CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test")) else { return false }
        let source = motionFrames
        let sourceSafe = source?.verifyRetiredCallbackIsInert() ?? false
        let before = (motion.progress, motion.velocity, panel.frame)
        stop(); collapse(); beginSmokeExpansion()
        return sourceSafe && smokeStopped && motion.progress == before.0 && motion.velocity == before.1
            && panel.frame == before.2 && panel.ignoresMouseEvents
    }
    /// Real AppKit panel checks with synthetic geometry/data; never a physical-notch claim.
    func verifyNativeGeometry() -> Bool {
        let keyWindow = NSApp.keyWindow
        var valid = true
        for progress in [0.0, 0.2, 0.65, 1, 0.7, 0.35, 0.8, 1, 0] {
            apply(progress: progress)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
            let expected = geometry.frame(progress: progress)
            let top = abs(panel.frame.maxY - geometry.screen.maxY) < 0.5
            let left = abs(panel.frame.minX - expected.minX) < 0.5
            let height = abs(panel.frame.height - expected.height) < 0.5
            let contentOrigin = panel.contentView?.frame.origin == CGPoint.zero
            let boundsOrigin = panel.contentView?.bounds.origin == CGPoint.zero
            let sameKey = NSApp.keyWindow === keyWindow
            let nonKey = !panel.canBecomeKey
            let ignoresMouse = panel.ignoresMouseEvents
            SmokeDiagnostics.mark("geometry p=\(progress) expected=\(expected) actual=\(panel.frame) content=\(String(describing: panel.contentView?.frame)) bounds=\(String(describing: panel.contentView?.bounds)) safeInsets=\(String(describing: panel.contentView?.safeAreaInsets)) top=\(top) left=\(left) height=\(height) contentOrigin=\(contentOrigin) boundsOrigin=\(boundsOrigin) sameKey=\(sameKey) nonKey=\(nonKey) ignoresMouse=\(ignoresMouse) placement=\(placementIsValid)")
            valid = [top, left, height, contentOrigin, boundsOrigin, sameKey, nonKey, ignoresMouse, valid].allSatisfy { $0 }
        }
        SmokeDiagnostics.mark(valid ? "native island top-frame and nonactivation checks passed" : "native island geometry failed")
        return valid && placementIsValid
    }
    func beginSmokeExpansion() {
        let point = CGPoint(x: geometry.notch.midX, y: geometry.screen.maxY - geometry.notch.height - 2)
        updatePointer(point, now: 0); updatePointer(point, now: 0.13)
    }
    func smokePointer(at point: CGPoint, now: TimeInterval) {
        guard CommandLine.arguments.contains("--motion-test") else { return }
        updatePointer(point, now: now)
    }
    func smokePointer(inside: Bool, now: TimeInterval) {
        let point = inside ? CGPoint(x: geometry.notch.midX, y: geometry.screen.maxY - geometry.notch.height - 2)
            : CGPoint(x: geometry.screen.minX - 10, y: geometry.screen.minY - 10)
        updatePointer(point, now: now)
    }
    var closePresentationPending: Bool { closeDrain.isPending }
    func verifyRetiredCloseIsInert() -> Bool {
        guard (CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test")), closeDrain.isPending,
              let deadline = closeDeadline, let source = motionFrames else { return false }
        let before = (motion.progress, motion.velocity, panel.frame)
        stop(); closeDeadlineReached(deadline)
        let retired = source.verifyRetiredCallbackIsInert()
        collapse(); beginSmokeExpansion()
        return retired && smokeStopped && !closeDrain.isPending && closeDeadline == nil
            && panel.frame == before.2 && motion.progress == before.0 && motion.velocity == before.1
    }
    var displaysColoredDetails: Bool { presentation.progress > 0.35 }
    var smokeNoticeVisible: Bool { presentation.notice != nil }
    var smokeNoticeID: UUID? { presentation.notice?.id }
    func verifyRetiredNoticeIsInert() -> Bool {
        guard CommandLine.arguments.contains("--update-test"), let timer = noticeExpiry else { return false }
        let before = (motion.progress, motion.velocity, panel.frame, presentation.notice?.id)
        stop(); expireNotice(timer)
        return smokeStopped && noticeExpiry == nil && motion.progress == before.0
            && motion.velocity == before.1 && panel.frame == before.2 && presentation.notice?.id == before.3
    }
    var smokeNoticeTargetActive: Bool { noticeTargetActive }
    var smokeTargetProgress: Double { motionTargetValue }
    var smokeProgress: Double { motion.progress }
    var smokeVelocity: Double { motion.velocity }
    var smokeRetarget: IslandMotionRetarget? { lastRetarget }
    var smokeMotionRunning: Bool { motionFrames != nil }
    var motionProbe: IslandMotionProbe {
        IslandMotionProbe(observed: CACurrentMediaTime(), frame: panel.frame,
            contentBounds: panel.contentView?.bounds ?? .zero,
            layerPresentation: panel.contentView?.layer?.presentation()?.bounds,
            viewport: renderedViewport, renderedProgress: renderedProgress, renderedAt: renderedAt,
            requestedProgress: presentation.progress, visible: panel.isVisible,
            nonKey: !panel.isKeyWindow && !panel.canBecomeKey, running: motionFrames != nil)
    }
    var smokeTargetExpanded: Bool { hover.isExpanded }
    var smokeStopped: Bool { stopped && pointerTimer == nil && motionFrames == nil && !panel.isVisible }
    func verifyDisplayStopIsInert() -> Bool {
        guard CommandLine.arguments.contains("--display-test") else { return false }
        let pointer = pointerTimer, source = motionFrames
        let frame = panel.frame, progress = motion.progress, velocity = motion.velocity
        stop()
        if let pointer { pollPointer(pointer) }
        let sourceSafe = source?.verifyRetiredCallbackIsInert() ?? true
        collapse(); beginSmokeExpansion()
        return pointer != nil && source != nil && sourceSafe && smokeStopped && panel.frame == frame
            && motion.progress == progress && motion.velocity == velocity && panel.ignoresMouseEvents
    }
    func verifySmokeClickRouting() -> Bool {
        let frame = geometry.frame(progress: 1)
        updateClickRouting(CGPoint(x: frame.midX, y: frame.minY + 100))
        let activeContent = !panel.ignoresMouseEvents && panel.contentView?.acceptsFirstMouse(for: nil) == true
        updateClickRouting(CGPoint(x: frame.minX + 1, y: frame.maxY - 1))
        return activeContent && panel.ignoresMouseEvents
    }
    private func verifyRenderedTopEdge() -> Bool {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
        // Both ends of the center column must be drawn. A hosting safe-area gap
        // would leave an undrawn end, regardless of bitmap row orientation.
        let x = bitmap.pixelsWide / 2
        let first = bitmap.colorAt(x: x, y: 0)?.alphaComponent ?? 0
        let last = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1)?.alphaComponent ?? 0
        let valid = first > 0.5 && last > 0.5
        SmokeDiagnostics.mark("bitmap edge alpha first=\(first) last=\(last) width=\(bitmap.pixelsWide) height=\(bitmap.pixelsHigh)")
        SmokeDiagnostics.mark(valid ? "native island bitmap edge coverage passed" : "native island bitmap edge coverage failed")
        return valid
    }
    var smokeExpanded: Bool { verifyExpandedLayout(includePixels: true) }
    func verifyExpandedLayout(includePixels: Bool) -> Bool {
        let contentHeight = geometry.expandedSize.height - geometry.notch.height - 8
        let quitVisible = quitFrame.width > 0 && quitFrame.height >= 20
            && CGRect(x: 0, y: 0, width: 304, height: contentHeight).contains(quitFrame)
        let frame = geometry.frame(progress: 1)
        let originX = frame.minX + geometry.contourRect(progress: 1).midX - 152
        let contentTop = frame.maxY - geometry.notch.height - 8
        let clickPoints = [
            CGPoint(x: originX + quitFrame.minX + 3, y: contentTop - quitFrame.minY - 3),
            CGPoint(x: originX + quitFrame.maxX - 3, y: contentTop - quitFrame.maxY + 3),
            CGPoint(x: originX + quitFrame.midX, y: contentTop - quitFrame.midY)
        ]
        let clickable = clickPoints.allSatisfy(geometry.interactiveContains)
        let rendered = !includePixels || verifyRenderedTopEdge()
        SmokeDiagnostics.mark("expanded progress=\(motion.progress) settled=\(motion.isSettled) visible=\(panel.isVisible) quit=\(quitFrame) contentHeight=\(contentHeight) quitVisible=\(quitVisible) clickable=\(clickable)")
        SmokeDiagnostics.mark(quitVisible && clickable ? "visible Quit layout and routing bounds passed" : "visible Quit layout or routing bounds failed")
        return motion.progress == 1 && motion.isSettled && panel.isVisible && quitVisible && clickable && rendered
    }
}
#endif
