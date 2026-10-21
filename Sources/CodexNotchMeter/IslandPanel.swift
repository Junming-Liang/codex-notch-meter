#if os(macOS)
import AppKit
import SwiftUI
import QuartzCore
import Combine
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

struct IslandPointerIngressReceipt {
    let point: CGPoint
    let timestamp: TimeInterval
    let kind: String
    let owner: IslandExpansionOwner
    let target: Double
    let hoverDecision: IslandPointerHoverDecision?
}

/// Present only when an explicit native-input fixture reaches hover.update.
/// The timestamp is that call's exact clock argument, never a delivery proxy.
struct IslandPointerHoverDecision: Equatable {
    let timestamp: TimeInterval
    let inside: Bool
    let expandedBefore: Bool
    let expandedAfter: Bool
}

/// Bounded, synthetic-gate-only evidence from before any input rejection.
struct IslandPointerEntryReceipt {
    let monitor: String
    let eventNumber: Int
    let eventType: UInt
    let windowNumber: Int
    let localPoint: CGPoint
    let screenPoint: CGPoint
    let timestamp: TimeInterval
    let delivered: TimeInterval
    let lastEventTime: TimeInterval
    let lastAppliedGestureTime: TimeInterval
    let buttonStateTime: TimeInterval
    let buttons: [Int]
    let stopped: Bool
    let placementValid: Bool
}

private struct IslandRenderState {
    let geometry: IslandGeometry
    let progress: Double
    let revision: UInt64
}
struct IslandRenderCommit {
    let revision: UInt64
    /// Publication begins here; this is not a post-resize measurement timestamp.
    let observed: TimeInterval
    let geometry: IslandGeometry
    let progress: Double
    /// Measured after this publication's setFrame; paint independently samples
    /// the actual window at draw time to reject a mixed old/new revision.
    let nativeFrame: CGRect
    let owner: IslandExpansionOwner
    let target: Double
}
@MainActor
private final class IslandPresentation: ObservableObject {
    @Published var frame: IslandRenderState
    var progress: Double { frame.progress }
    var geometry: IslandGeometry { frame.geometry }
    @Published var notice: RefreshNotice?
    @Published var showingDetails = true
    @Published var showingMusic = false
    init(geometry: IslandGeometry) { frame = IslandRenderState(geometry: geometry, progress: 0, revision: 0) }
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
    let frameRevision: UInt64
    let progress: Double
    let accessoryProgress: Double
    let size: CGSize
    let noticeID: UUID?
    let musicRevision: UInt64
}

@MainActor
private struct IslandRootView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var presentation: IslandPresentation
    @ObservedObject var music: MusicLyricsController
    var geometry: IslandGeometry { presentation.geometry }
    let motionProfile: IslandMotionProfile
    let refresh: () -> Void
    let settings: () -> Void
    let quit: () -> Void
    let quitFrameChanged: (CGRect) -> Void
    let viewportChanged: (CGSize) -> Void
    let rendered: (Double, CGSize) -> Void
    let paintStore: IslandPaintStore
    var body: some View {
        let snapshot = presentation.frame
        let geometry = snapshot.geometry
        let p = snapshot.progress
        let promoting = presentation.notice != nil || presentation.showingMusic
        let musicHeight = music.previewContentHeight(width: geometry.compactContentWidth)
        // Reveal thresholds depend on fixed geometry, never on a changing cue.
        let promotionProgress = presentation.notice != nil ? geometry.updateProgress : geometry.musicProgress(contentHeight: 90)
        let detailReveal = promoting ? IslandReveal.smooth((p - promotionProgress) / (1 - promotionProgress)) : IslandReveal.details(p)
        GeometryReader { viewport in
            let visual = IslandVisualFrame(geometry: geometry, progress: p, viewport: viewport.size,
                frameRevision: snapshot.revision, noticeID: presentation.notice?.id, musicRevision: music.presentationRevision, baseline: motionProfile.forcesLayout,
                musicPerimeter: music.isPlayingForPresentation && music.lyricsModeEnabled)
            let window = model.primaryWindow
            let remaining = window?.remainingPercent
            let pending = window?.resetPending(at: model.now) ?? false
            IslandPaintView(frame: visual, remaining: remaining, theme: model.theme,
                colorPhase: model.skinPhase, dimmed: model.degraded || pending, store: paintStore)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(window.map { "主额度 · " + windowTitle($0) } ?? "额度不可用")
                .accessibilityValue((remaining.map { "剩余 \(Int($0.rounded()))%" } ?? "未知") + (model.degraded ? "，上次读取" : "") + (pending ? "，等待刷新确认" : ""))
                .accessibilityHidden(p > 0.1)
                .overlay(alignment: .topLeading) {
                    // Opacity-zero fixed-height content MUST NOT size the collapsed root.
                    if motionProfile.prewarmsDetails || p > 0 {
                        CompactDetailView(model: model, music: music, width: geometry.detailContentWidth, height: geometry.contentHeight, quitFrameChanged: quitFrameChanged, refresh: refresh, settings: settings, quit: quit)
                            .frame(width: geometry.detailContentWidth)
                            .offset(x: geometry.expandedContentCenterX - geometry.frame(progress: p).minX - geometry.detailContentWidth / 2,
                                    y: geometry.notch.height + 8 + (motionProfile.forcesLayout ? 0 : (1 - detailReveal) * 6))
                            .opacity(presentation.showingDetails ? (motionProfile.forcesLayout ? min(1, max(0, (p - 0.35) / 0.5)) : detailReveal) : 0)
                            .allowsHitTesting(p == 1 && presentation.showingDetails)
                            .accessibilityHidden(p < 1)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if presentation.showingMusic {
                        MusicCompactView(music: music)
                            .frame(width: geometry.compactContentWidth, height: musicHeight)
                            .offset(x: geometry.expandedContentCenterX - geometry.frame(progress: p).minX - geometry.compactContentWidth / 2,
                                    y: geometry.notch.height + 8)
                            .opacity(IslandReveal.smooth(p / geometry.musicProgress(contentHeight: 48)) * (presentation.showingDetails ? 1 - detailReveal : 1))
                            .allowsHitTesting(false).accessibilityHidden(p == 0)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let notice = presentation.notice {
                        RefreshNoticeView(notice: notice)
                            .frame(width: geometry.noticeContentWidth, height: 62)
                            .offset(x: geometry.expandedContentCenterX - geometry.frame(progress: p).minX - geometry.noticeContentWidth / 2,
                                    y: geometry.notch.height + 8)
                            .opacity(IslandReveal.smooth(p / geometry.updateProgress) * (presentation.showingDetails ? 1 - detailReveal : 1))
                            .allowsHitTesting(false).accessibilityHidden(p == 0)
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .overlay(alignment: .topLeading) {
                    if geometry.showsMusicAccessories {
                        let rects = geometry.musicAccessoryRects(progress: p)
                        MusicClosedAccessories(music: music, left: rects.left, right: rects.right,
                            visible: geometry.musicAccessoryProgress > 0 && p < geometry.musicProgress(contentHeight: 48))
                            .opacity(geometry.musicAccessoryProgress * (1 - IslandReveal.smooth(p / geometry.musicProgress(contentHeight: 48))))
                            .allowsHitTesting(false).accessibilityHidden(p > 0)
                    }
                }
                .clipShape(visual.bodyPath)
                .onAppear { viewportChanged(viewport.size); rendered(p, viewport.size) }
                // A single coherent observation avoids a resize callback overwriting
                // the new progress with the previous body's captured progress.
                .onChange(of: IslandRenderObservation(frameRevision: snapshot.revision, progress: p, accessoryProgress: geometry.musicAccessoryProgress, size: viewport.size, noticeID: presentation.notice?.id, musicRevision: music.presentationRevision)) { observation in
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

/// Synthetic ordinary-path proof, captured synchronously at the retarget boundary.
struct IslandWidthHandoffReceipt {
    let sequence: UInt64
    let eventTime: TimeInterval
    let integratedTime: TimeInterval
    let before: IslandWidthSample
    let after: IslandWidthSample
    let target: IslandWidthSample
    let oldProfile: String
    let owner: IslandExpansionOwner
}

struct IslandCloseReceipt {
    let requestedAt: TimeInterval
    let acknowledgedAt: TimeInterval?
    let completedAt: TimeInterval?
    let finalDisplayDuration: TimeInterval
    let renderedAt: TimeInterval?
    let paintedAt: TimeInterval?
    let outcome: ClosePresentationDrain.Outcome
}

@MainActor
final class IslandPanelController: NSObject {
    private let model: MeterModel
    private let debugToken = UUID()
    private var debugLastOwner: IslandExpansionOwner?
    private var debugSession: UUID?
    private var debugLastHoverInside: Bool?
    private var debugLastPollTick: TimeInterval?
    private var debugFrameRevisionBase: UInt64 = 0
    private var debugMusicRevisionBase: UInt64 = 0
    var geometry: IslandGeometry { presentation.geometry }
    let panel: TopEdgePanel
    private let presentation: IslandPresentation
    private let paintStore = IslandPaintStore()
    private var pendingGeometry: IslandGeometry?
    private var hover = IslandHoverState()
    private var crossing = IslandCrossing()
    private var gestureHoverGate = IslandGestureHoverGate()
    private var musicGestureNeedsCorridorExit = false
    private var smokePolledPointer: CGPoint?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var lastEventTime: TimeInterval = -.infinity
    private var lastPollTime: TimeInterval = -.infinity
    private var lastEventDelivery: TimeInterval = -.infinity
    private var lastAppliedGestureTime: TimeInterval = -.infinity
    private var fallbackCrossing = IslandCrossing()
    private var musicHoverReservation = IslandMusicHoverReservation()
    private var eventButtons: Set<Int> = []
    private var buttonStateTime: TimeInterval = -.infinity
    private(set) var smokeHistoryOverflow = false
    var smokePaintHistoryOverflow: Bool { paintStore.historyOverflow }
    private(set) var smokePointerIngress: [IslandPointerIngressReceipt] = []
    private(set) var smokePointerEntries: [IslandPointerEntryReceipt] = []
    private(set) var smokePointerEntriesOverflow = false
    private(set) var smokeRenderCommits: [IslandRenderCommit] = []
    var smokePaintHistory: [IslandPaintReceipt] { paintStore.history() }
    private enum PointerSource { case event, poll, synthetic }
    private var ordinaryWidthCycle = false
    private var widthBridge: IslandWidthBridge?
    private var widthHandoffSequence: UInt64 = 0
    private(set) var smokeWidthHandoffReceipt: IslandWidthHandoffReceipt?
    private var accessoryMotion = IslandMotion()
    private var accessoryTarget = false
    private var observedPlaybackRevision: UUID?
    private var motion = IslandMotion()
    private var pointerTimer: Timer?
    private var motionFrames: IslandFrameSource?
    private var frameGeneration = 0
    private var motionTargetExpanded = false
    private var motionTargetValue: Double = 0
    private var noticeExpiry: Timer?
    private var noticeReadiness: Timer?
    private var noticeReadyWaitStarted: TimeInterval?
    private var noticeReadinessDeadline: TimeInterval?
    private var noticePaintRequiredAfter: TimeInterval = 0
    private var smokeNoticeReadinessNotBefore: TimeInterval = 0
    private(set) var smokeNoticeArmedAt: TimeInterval?
    private(set) var smokeNoticePaintReadyAt: TimeInterval?
    private var noticeTargetActive = false
    private var musicEligible = false
    private var passiveMusicAllowed: Bool
    private var musicSubscription: AnyCancellable?
    private var expansionOwner: IslandExpansionOwner {
        .resolve(hoverExpanded: hover.isExpanded, noticeActive: noticeTargetActive,
                 musicEligible: musicEligible, passiveMusicAllowed: passiveMusicAllowed)
    }
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
    private let testFrameFactory: IslandFrameFactory?

    init(model: MeterModel, geometry: IslandGeometry, startPolling: Bool = true, reducedMotionOverride: Bool? = nil,
         motionProfile: IslandMotionProfile = .adaptive, drainsClosePresentation: Bool = true, motionSample: ((IslandMotionSample) -> Void)? = nil,
         musicPresentationAllowed: Bool = true, testFrameFactory: IslandFrameFactory? = nil,
         activityChanged: @escaping () -> Void = {}, hovered: @escaping () -> Void, refresh: @escaping () -> Void,
         settings: @escaping () -> Void, quit: @escaping () -> Void) {
        let motionDiagnostic = model.demo && (CommandLine.arguments.contains("--motion-test") || (CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test")))
        self.motionProfile = motionDiagnostic ? motionProfile : .adaptive
        self.drainsClosePresentation = model.demo && (CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test")) ? drainsClosePresentation : true
        self.motionSample = motionSample
        self.testFrameFactory = model.demo && CommandLine.arguments.contains("--music-cache-test") ? testFrameFactory : nil
        self.model = model
        self.passiveMusicAllowed = musicPresentationAllowed
        self.musicEligible = model.music.isPlayingForPresentation && model.music.lyricsModeEnabled
        self.presentation = IslandPresentation(geometry: geometry); self.hovered = hovered; self.activityChanged = activityChanged; self.reducedMotionOverride = reducedMotionOverride
        panel = TopEdgePanel(contentRect: geometry.frame(progress: 0), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.animationBehavior = .none; panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let hosting = IslandHostingView(rootView: IslandRootView(model: model, presentation: presentation, music: model.music,
            motionProfile: self.motionProfile, refresh: refresh, settings: settings, quit: quit,
            quitFrameChanged: { [weak self] in self?.quitFrame = $0 },
            viewportChanged: { [weak self] in self?.renderedViewport = $0 },
            rendered: { [weak self] progress, size in
                self?.renderedProgress = progress; self?.renderedViewport = size; self?.renderedAt = CACurrentMediaTime()
            }, paintStore: paintStore))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.sizingOptions = []
        if #available(macOS 14.0, *) { hosting.safeAreaRegions = [] }
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        paintStore.setNativeGeometryProvider { [weak panel] in
            (panel?.frame ?? .zero, panel?.contentView?.bounds ?? .zero)
        }
        apply(progress: 0)
        panel.orderFrontRegardless()
        apply(progress: 0)
        if startPolling {
            // Only this explicit native fixture adds timing observation. Normal
            // users keep the original selector and incur no per-tick tracing.
            let timingDiagnostic = model.demo && CommandLine.arguments.contains("--music-test")
                && CommandLine.arguments.contains("--music-cache-test")
                && CommandLine.arguments.contains("--music-stationary-hover-test")
                && !CommandLine.arguments.contains("--music-wide-quota-hover-test")
            let selector = timingDiagnostic ? #selector(diagnosticPollPointer(_:)) : #selector(pollPointer(_:))
            let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: selector, userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common); pointerTimer = timer
            // Mouse-only AppKit observation needs no accessibility event tap.
            // Local and global monitors cover our window and other applications;
            // polling remains a fallback and handles stationary hover/exit dwell.
            let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved,
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.observePointer(event: event, monitor: "global") }
            }
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
                MainActor.assumeIsolated { self?.observePointer(event: event, monitor: "local") }
                return event
            }
        }
        musicSubscription = model.music.$presentationRevision.removeDuplicates().sink { [weak self] _ in
            // @Published sends before its source mutation completes. Queue only
            // a bounded state edge; identical playback polls do not retarget.
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateMusicPresentation()
            }
        }
        updateMusicPresentation(forceRetarget: expansionOwner == .music)
        recordDebugSnapshot()
    }
    /// Records only safe dimensions and notch-relative offsets, never a display
    /// identity, desktop origin, other-window identity, or content.
    func recordDebugSnapshot() {
        let capture = model.debugCapture.recorder
        guard capture.isRecording else { return }
        if debugSession != capture.sessionID {
            debugSession = capture.sessionID; debugLastOwner = nil; debugLastHoverInside = nil
            debugLastPollTick = nil; debugFrameRevisionBase = presentation.frame.revision
            debugMusicRevisionBase = model.music.presentationRevision
        }
        capture.record(.geometry, island: capture.identifier(debugToken), values: [
            .screenWidth: Double(geometry.screen.width), .screenHeight: Double(geometry.screen.height),
            .scale: Double(geometry.backingScale), .notchWidth: Double(geometry.notch.width),
            .notchHeight: Double(geometry.notch.height), .horizontalAdjustment: geometry.horizontalAdjustment,
            .widthAdjustment: geometry.shapeCalibration.width, .depthAdjustment: geometry.shapeCalibration.depth,
            .cornerAdjustment: geometry.shapeCalibration.corner, .reducedMotion: reducedMotion ? 1 : 0],
            labels: [.reason: .geometryChanged])
        debugState(.ownership, reason: .snapshot)
    }
    private func debugOwner(_ owner: IslandExpansionOwner) -> DebugCapture.Value {
        switch owner { case .idle: return .idle; case .music: return .music
        case .quotaNotice: return .quotaNotice; case .details: return .details }
    }
    private func debugState(_ event: DebugCapture.Event, reason: DebugCapture.Value,
                           sampled: Bool = false, source: DebugCapture.Value? = nil,
                           sourceTime: TimeInterval? = nil, point: CGPoint? = nil,
                           inside: Bool? = nil, expandedBefore: Bool? = nil,
                           anchor: CGPoint? = nil, extra: [DebugCapture.Field: Double] = [:]) {
        let capture = model.debugCapture.recorder
        guard capture.isRecording else { return }
        if debugSession != capture.sessionID {
            debugSession = capture.sessionID; debugLastOwner = nil; debugLastHoverInside = nil
            debugLastPollTick = nil; debugFrameRevisionBase = presentation.frame.revision
            debugMusicRevisionBase = model.music.presentationRevision
        }
        func diagnosticValues() -> [DebugCapture.Field: Double] {
            var values: [DebugCapture.Field: Double] = [
                .progress: motion.progress, .target: motionTargetValue, .velocity: motion.velocity,
                .accessory: accessoryMotion.progress, .accessoryTarget: accessoryTarget ? 1 : 0,
                .widthBridge: widthBridge == nil ? 0 : 1, .fresh: model.music.isFreshPlaying ? 1 : 0,
                .playing: model.music.isPlayingForPresentation ? 1 : 0, .lyricsMode: model.music.lyricsModeEnabled ? 1 : 0,
                .allowed: passiveMusicAllowed ? 1 : 0, .expandedAfter: hover.isExpanded ? 1 : 0,
                .corridorExitRequired: musicGestureNeedsCorridorExit ? 1 : 0,
                .gestureGate: gestureHoverGate.isSuppressing ? 1 : 0,
                .frameRevision: Double(presentation.frame.revision &- debugFrameRevisionBase),
                .presentationRevision: Double(model.music.presentationRevision &- debugMusicRevisionBase),
                .playbackRevision: capture.identifier(model.music.playbackRevision)]
            if let id = presentation.notice?.id { values[.noticeRevision] = capture.identifier(id) }
            if let sourceTime {
                values[.sourceOffsetMs] = capture.offsetMilliseconds(sourceTime)
                values[.sourceAgeMs] = (ProcessInfo.processInfo.systemUptime - sourceTime) * 1000
            }
            if let inside { values[.inside] = inside ? 1 : 0 }
            if let expandedBefore { values[.expandedBefore] = expandedBefore ? 1 : 0 }
            // Only points inside our own current interaction neighborhood are logged.
            // Outside events retain classification/counts but no cursor coordinates.
            let near = geometry.frame(progress: 1).insetBy(dx: -32, dy: -32)
            if let point, near.contains(point) {
                values[.pointerX] = Double(point.x - geometry.calibratedNotch.midX)
                values[.pointerY] = Double(point.y - geometry.calibratedNotch.maxY)
                if let fixed = anchor ?? musicHoverReservation.stationaryAnchor, near.contains(fixed) {
                    values[.anchorX] = Double(fixed.x - geometry.calibratedNotch.midX)
                    values[.anchorY] = Double(fixed.y - geometry.calibratedNotch.maxY)
                }
            }
            values.merge(extra) { _, new in new }
            return values
        }
        var labels: [DebugCapture.Label: DebugCapture.Value] = [.reason: reason, .owner: debugOwner(expansionOwner)]
        if let source { labels[.source] = source }
        if event == .ownership {
            if let previous = debugLastOwner { labels[.previousOwner] = debugOwner(previous) }
            debugLastOwner = expansionOwner
        }
        capture.record(event, island: capture.identifier(debugToken), sampled: sampled, values: diagnosticValues(), labels: labels)
    }
    func updateGeometry(_ value: IslandGeometry) {
        guard !stopped, geometry.hasSameAnchor(as: value) else { return }
        // Freeze the content-fit endpoint through an open interaction. New data remains
        // scrollable now; its smaller/larger endpoint is adopted only at the next idle.
        var corrected = value
        corrected.showsMusicAccessories = geometry.showsMusicAccessories && value.canShowMusicAccessories
        corrected.musicAccessoryProgress = geometry.musicAccessoryProgress
        pendingGeometry = corrected
        debugState(.lifecycle, reason: .geometryChanged)
        if motion.progress == 0 && !motionTargetExpanded && !closeDrain.isPending { apply(progress: 0) }
    }
    private func apply(progress: Double) {
        guard !stopped else { return }
        model.debugCapture.recorder.count(.frameApplies)
        var nextGeometry = presentation.geometry
        var adoptedGeometry = false
        if progress == 0, widthBridge == nil, accessoryMotion.isSettled(at: accessoryTarget ? 1 : 0), let pendingGeometry {
            nextGeometry = pendingGeometry; self.pendingGeometry = nil; adoptedGeometry = true
        }
        nextGeometry.showsMusicAccessories = (accessoryTarget || accessoryMotion.progress > 0)
            && nextGeometry.canShowMusicAccessories
        nextGeometry.musicAccessoryProgress = accessoryMotion.progress
        nextGeometry.ordinaryHoverWidth = ordinaryWidthCycle
        nextGeometry.widthPresentation = widthBridge.map { IslandWidthPresentation(progress: progress, sample: $0.sample) }
        let hadDetails = displaysColoredDetails
        if (progress == 0 && !noticeTargetActive) || (progress == 1 && hover.isExpanded) {
            if presentation.notice != nil { presentation.notice = nil }
            if presentation.showingMusic { presentation.showingMusic = false }
            if !presentation.showingDetails { presentation.showingDetails = true }
        }
        // Preserve the v1.0.0 publish-then-resize order. The new accessory
        // geometry and expansion progress are still one immutable revision.
        let expected = nextGeometry.frame(progress: progress)
        let changed = presentation.progress != progress || presentation.geometry != nextGeometry
        let revision = presentation.frame.revision &+ (changed ? 1 : 0)
        let committedAt = CACurrentMediaTime()
        if changed {
            presentation.frame = IslandRenderState(geometry: nextGeometry, progress: progress, revision: revision)
        }
        if adoptedGeometry { recordDebugSnapshot() }
        if hadDetails != displaysColoredDetails { activityChanged() }
        if panel.frame != expected { panel.setFrame(expected, display: motionProfile.forcesLayout) }
        paintStore.recordNativeFrame(panel.frame, contentBounds: panel.contentView?.bounds ?? .zero)
        if changed, model.demo, CommandLine.arguments.contains("--music-test") {
            if smokeRenderCommits.count >= 4096 { smokeHistoryOverflow = true; smokeRenderCommits.removeFirst(2048) }
            smokeRenderCommits.append(IslandRenderCommit(revision: revision, observed: committedAt,
                geometry: nextGeometry, progress: progress, nativeFrame: panel.frame,
                owner: expansionOwner, target: motionTargetValue))
        }
        if changed, model.debugCapture.recorder.isRecording {
            debugState(.frame, reason: .accepted, sampled: true, extra: [
                .width: Double(panel.frame.width), .height: Double(panel.frame.height),
                .centerOffset: Double(panel.frame.midX - geometry.calibratedNotch.midX),
                .topError: Double(panel.frame.maxY - geometry.screen.maxY),
                .applyMs: (CACurrentMediaTime() - committedAt) * 1000])
        }
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
    @objc private func diagnosticPollPointer(_ timer: Timer) {
        let entered = ProcessInfo.processInfo.systemUptime
        let previousPoll = lastPollTime
        let eventDelivery = lastEventDelivery
        let validTimer = timer === pointerTimer
        let wasStopped = stopped, validPlacement = placementIsValid
        pollPointer(timer)
        // No coordinates or user content. Synchronous own-process delivery
        // lets the fixture retain bounded evidence without adding another clock.
        NotificationCenter.default.post(name: Notification.Name("CodexNotchMeter.StationaryPollTiming"),
            object: self, userInfo: ["row": [entered, ProcessInfo.processInfo.systemUptime,
                eventDelivery.isFinite ? eventDelivery : -1,
                previousPoll.isFinite ? previousPoll : -1,
                lastPollTime.isFinite ? lastPollTime : -1,
                validTimer ? 1.0 : 0, wasStopped ? 1.0 : 0, validPlacement ? 1.0 : 0]])
    }
    @objc private func pollPointer(_ timer: Timer) {
        guard !stopped, timer === pointerTimer, placementIsValid else { return }
        // This own-event fixture isolates queued AppKit input from the unrelated
        // physical cursor. The separate cache gate still exercises real polling.
        guard !(model.demo && CommandLine.arguments.contains("--music-test")
            && CommandLine.arguments.contains("--gesture-recovery-test")) else { return }
        observePointer()
    }
    private func resetCrossings() { crossing.reset(); fallbackCrossing.reset() }
    private func releaseMusicGestureToHover() {
        gestureHoverGate.reset()
        musicHoverReservation.reset()
        // The event and fallback histories intentionally reset each other.
        // Keep this cancellation outside either recognizer so switching sources
        // cannot reserve the same stationary endpoint again after a failed open.
        musicGestureNeedsCorridorExit = true
        resetCrossings()
        if !hover.isExpanded { hover.reset() }
        musicHoverReservation.resetDwell()
    }
    private func recordPointer(_ point: CGPoint, timestamp: TimeInterval, kind: String,
                               hoverDecision: IslandPointerHoverDecision? = nil) {
        guard model.demo, CommandLine.arguments.contains("--music-test") else { return }
        if smokePointerIngress.count >= 2048 { smokeHistoryOverflow = true; smokePointerIngress.removeFirst(1024) }
        smokePointerIngress.append(IslandPointerIngressReceipt(point: point, timestamp: timestamp,
            kind: kind, owner: expansionOwner, target: motionTargetValue, hoverDecision: hoverDecision))
    }
    private func observePointer(event: NSEvent? = nil, monitor: String = "poll") {
        let debugSource: DebugCapture.Value = event == nil ? .poll : (monitor == "local" ? .localEvent : .globalEvent)
        model.debugCapture.recorder.count(event == nil ? .polls : (monitor == "local" ? .localEvents : .globalEvents))
        if let event, model.demo, CommandLine.arguments.contains("--music-test"),
           CommandLine.arguments.contains("--pointer-ingress-test")
            || CommandLine.arguments.contains("--music-cache-test") {
            if smokePointerEntries.count < 256 {
                smokePointerEntries.append(IslandPointerEntryReceipt(monitor: monitor,
                    eventNumber: event.eventNumber, eventType: event.type.rawValue, windowNumber: event.windowNumber,
                    localPoint: event.locationInWindow,
                    screenPoint: event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow,
                    timestamp: event.timestamp, delivered: ProcessInfo.processInfo.systemUptime,
                    lastEventTime: lastEventTime, lastAppliedGestureTime: lastAppliedGestureTime,
                    buttonStateTime: buttonStateTime, buttons: eventButtons.sorted(), stopped: stopped,
                    placementValid: placementIsValid))
            } else { smokePointerEntriesOverflow = true }
        }
        guard !stopped, placementIsValid else { return }
        let delivered = ProcessInfo.processInfo.systemUptime
        if event == nil, model.debugCapture.recorder.isRecording {
            let capture = model.debugCapture.recorder
            if debugSession != capture.sessionID { recordDebugSnapshot() }
            capture.count(.pollCallbacks)
            var values: [DebugCapture.Field: Double] = [.deliveredOffsetMs: capture.offsetMilliseconds(delivered)]
            if let previous = debugLastPollTick { values[.rawPollGapMs] = (delivered - previous) * 1000 }
            debugLastPollTick = delivered
            capture.record(.pollTick, island: capture.identifier(debugToken), sampled: true,
                           values: values, labels: [.source: .poll])
        }
        if model.debugCapture.recorder.isRecording {
            let capture = model.debugCapture.recorder
            var values: [DebugCapture.Field: Double] = [.deliveredOffsetMs: capture.offsetMilliseconds(delivered)]
            if let event { values[.sourceOffsetMs] = capture.offsetMilliseconds(event.timestamp) }
            if lastEventDelivery.isFinite { values[.eventGapMs] = (delivered - lastEventDelivery) * 1000 }
            if lastPollTime.isFinite { values[.pollGapMs] = (delivered - lastPollTime) * 1000 }
            capture.record(event == nil ? .pollIngress : .inputIngress, island: capture.identifier(debugToken), sampled: true,
                           values: values, labels: [.source: debugSource])
        }
        if let event {
            // Preserve the event stream. Re-reading mouseLocation here turns a
            // queued traversal into many copies of the cursor's final position.
            let isMove = event.type == .mouseMoved
            // Even a duplicate-timestamp button is a trajectory boundary.
            if !isMove { musicHoverReservation.reset(); resetCrossings(); if !hover.isExpanded { hover.reset() }; musicHoverReservation.resetDwell() }
            guard event.timestamp.isFinite, event.timestamp >= lastEventTime else {
                model.debugCapture.recorder.count(.rejectedEvents)
                debugState(.input, reason: .staleEvent, sampled: true, source: debugSource, sourceTime: event.timestamp); return
            }
            if !isMove, event.timestamp >= buttonStateTime {
                buttonStateTime = event.timestamp
                switch event.type {
                case .leftMouseUp, .rightMouseUp, .otherMouseUp: eventButtons.remove(event.buttonNumber)
                default: eventButtons.insert(event.buttonNumber)
                }
            }
            guard !isMove || event.timestamp > lastEventTime else {
                model.debugCapture.recorder.count(.rejectedEvents)
                debugState(.input, reason: .duplicateEvent, sampled: true, source: debugSource, sourceTime: event.timestamp); return
            }
            lastEventTime = event.timestamp; lastEventDelivery = delivered
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
                ?? event.locationInWindow
            guard event.timestamp > lastAppliedGestureTime else {
                debugState(.input, reason: .staleEvent, sampled: true, source: debugSource, sourceTime: event.timestamp)
                recordPointer(point, timestamp: event.timestamp, kind: "stale")
                return
            }
            fallbackCrossing.reset()
            guard event.type == .mouseMoved else {
                resetCrossings(); musicHoverReservation.resetDwell()
                lastAppliedGestureTime = max(lastAppliedGestureTime, event.timestamp)
                debugState(.input, reason: .button, sampled: true, source: debugSource, sourceTime: event.timestamp)
                recordPointer(point, timestamp: event.timestamp, kind: "button")
                return
            }
            debugState(.input, reason: .accepted, sampled: true, source: debugSource, sourceTime: event.timestamp, point: point)
            let hoverDecision = updatePointer(point, now: event.timestamp, buttonDownOverride: !eventButtons.isEmpty, source: .event)
            recordPointer(point, timestamp: event.timestamp, kind: "event", hoverDecision: hoverDecision)
        } else {
            // Polling has its own history. It cannot insert the live cursor into
            // an event traversal, release its gate, or overwrite its timestamps.
            guard delivered > lastPollTime, delivered - lastEventDelivery > 0.25 else {
                model.debugCapture.recorder.count(.quietPolls)
                debugState(.input, reason: .quietWindow, sampled: true, source: .poll); return
            }
            lastPollTime = delivered
            model.debugCapture.recorder.count(.acceptedPolls)
            crossing.reset()
            // Native fixtures may supply a synthetic location without moving
            // the system cursor. The real timer, quiet guard and clock still run.
            let point = smokePolledPointer ?? NSEvent.mouseLocation
            let buttons = NSEvent.pressedMouseButtons
            // A lost up event must not permanently disable gestures. Polling
            // reconciles button state only after the event stream is quiet.
            eventButtons = Set((0..<32).filter { buttons & (1 << $0) != 0 })
            buttonStateTime = delivered
            debugState(.input, reason: .accepted, sampled: true, source: .poll, sourceTime: delivered, point: point)
            let hoverDecision = updatePointer(point, now: delivered, buttonDownOverride: buttons != 0, source: .poll)
            recordPointer(point, timestamp: delivered, kind: "poll", hoverDecision: hoverDecision)
        }
    }
    @discardableResult
    private func updatePointer(_ point: CGPoint, now: TimeInterval, buttonDownOverride: Bool? = nil,
                               source: PointerSource = .synthetic) -> IslandPointerHoverDecision? {
        guard !stopped, point.x.isFinite, point.y.isFinite, now.isFinite else { return nil }
        // A passive pointer cannot consume the user's configured readable dwell.
        // Keep hover history empty so expiry cannot inherit an already-armed hover.
        if noticeTargetActive {
            debugState(.hover, reason: .noticeOwns, sampled: true, sourceTime: now)
            hover.reset(); resetCrossings(); musicHoverReservation.reset(); gestureHoverGate.claim()
            panel.ignoresMouseEvents = true
            return nil
        }
        let corridor = geometry.musicGestureCorridor
        if musicGestureNeedsCorridorExit,
           point.x < corridor.minX || point.x > corridor.maxX
            || point.y < corridor.minY || point.y > corridor.maxY {
            musicGestureNeedsCorridorExit = false
            resetCrossings()
        }
        let gestureEnabled = model.music.isFreshPlaying && passiveMusicAllowed
            && !musicGestureNeedsCorridorExit && !noticeTargetActive
        // Ownership uses one delivery-clock lease across both input histories.
        // Native event timestamps remain untouched for gesture recognition.
        let reservationNow = source == .synthetic ? now : ProcessInfo.processInfo.systemUptime
        let insideCorridor = point.x >= corridor.minX && point.x <= corridor.maxX
            && point.y >= corridor.minY && point.y <= corridor.maxY
        let buttonDown = buttonDownOverride ?? (NSEvent.pressedMouseButtons != 0)
        var recognizer = source == .poll ? fallbackCrossing : crossing
        let action = recognizer.update(point: point, now: now, corridor: corridor,
            enabled: gestureEnabled, buttonDown: buttonDown)
        if source == .poll { fallbackCrossing = recognizer } else { crossing = recognizer }
        let reservesHover = musicHoverReservation.reservesPointer(recognizer.reservesPointer,
            insideCorridor: insideCorridor, enabled: gestureEnabled && !buttonDown, now: reservationNow)
        if let action, source == .synthetic || now > lastAppliedGestureTime {
            if source != .synthetic { lastAppliedGestureTime = now }
            let hadHover = hover.isExpanded
            model.music.selectLyricsMode(action == .right)
            if action == .right,
               !model.music.lyricsModeEnabled || !model.music.isPlayingForPresentation {
                debugState(.hover, reason: .gestureUnavailable, sourceTime: now, point: point)
                releaseMusicGestureToHover()
                updateClickRouting(point)
                return nil
            }
            debugState(.hover, reason: .gestureAccepted, sourceTime: now, point: point)
            hover.reset()
            gestureHoverGate.claim(requiresLyrics: action == .right)
            updateMusicPresentation(forceRetarget: hadHover)
            updateClickRouting(point)
            return nil
        }
        // A successful crossing owns this corridor until exit. Stationary center
        // entry is still ordinary hover and never toggles the selected mode.
        if reservesHover { debugState(.hover, reason: .reserved, sampled: true, sourceTime: now, point: point); updateClickRouting(point); return nil }
        if gestureHoverGate.suppresses(insideStableEnvelope: geometry.canonicalHoverContains(point, progress: 1)) {
            debugState(.hover, reason: .gestureGate, sampled: true, sourceTime: now, point: point)
            updateClickRouting(point); return nil
        }
        // A moving pointer near the music shell is approaching a gesture, not
        // asking to open full details. Allow small hand jitter around a fixed dwell anchor.
        if model.music.isFreshPlaying, !hover.isExpanded {
            let priorAnchor = model.debugCapture.recorder.isRecording ? musicHoverReservation.stationaryAnchor : nil
            if musicHoverReservation.shouldResetDwell(at: point) {
                debugState(.hover, reason: .dwellReset, sourceTime: now, point: point, anchor: priorAnchor)
                hover.reset()
            }
        } else { musicHoverReservation.resetDwell() }
        let before = hover.isExpanded
        // Preserve argument evaluation order: hit testing precedes the one clock
        // read used by the actual hover decision.
        let inside = currentHoverContains(point)
        if !inside { musicHoverReservation.resetDwell() }
        let hoverNow = source == .synthetic ? now : ProcessInfo.processInfo.systemUptime
        hover.update(inside: inside, now: hoverNow,
            resumeExpanded: !model.music.isFreshPlaying && ((motion.progress > 0 || closeDrain.isPending) && !motionTargetExpanded))
        model.debugCapture.recorder.count(.hoverDecisions)
        if model.debugCapture.recorder.isRecording {
            let edge = debugLastHoverInside != inside || hover.isExpanded != before
            debugLastHoverInside = inside
            debugState(.hover, reason: hover.isExpanded != before ? (hover.isExpanded ? .enter : .leave) : .hoverDecision,
                sampled: !edge, source: source == .event ? .unknown : (source == .poll ? .poll : .synthetic),
                sourceTime: now, point: point, inside: inside, expandedBefore: before,
                extra: [.decisionOffsetMs: model.debugCapture.recorder.offsetMilliseconds(hoverNow)])
        }
        let hoverDecision: IslandPointerHoverDecision?
        if model.demo, CommandLine.arguments.contains("--music-test"),
           (CommandLine.arguments.contains("--music-cache-test") || CommandLine.arguments.contains("--pointer-ingress-test")),
           source != .synthetic {
            hoverDecision = IslandPointerHoverDecision(timestamp: hoverNow, inside: inside,
                expandedBefore: before, expandedAfter: hover.isExpanded)
        } else { hoverDecision = nil }
        if hover.isExpanded != before {
            if source != .synthetic { lastAppliedGestureTime = max(lastAppliedGestureTime, now) }
            if hover.isExpanded { hovered(); cancelNoticeTimers(); noticeTargetActive = false; presentation.showingDetails = true }
            else { noticeTargetActive = false }
            startMotion(reason: hover.isExpanded ? .enter : .leave)
        }
        updateClickRouting(point)
        return hoverDecision
    }
    // Retargeting integrates the springs before the next frame publication. A
    // bridge override belongs to its published progress, so hit-test that same
    // displayed snapshot instead of silently falling back to the shared map.
    private var currentHoverProgress: Double {
        widthBridge != nil || geometry.widthPresentation != nil ? presentation.progress : motion.progress
    }
    private func currentHoverContains(_ point: CGPoint) -> Bool {
        // Expanded hover owns details, even if the user's lyric-mode preference
        // remains selected underneath. Passive lyrics never enable this hold.
        geometry.hoverContains(point, progress: currentHoverProgress,
            retainingMusicOrigin: model.music.isFreshPlaying && hover.isExpanded)
    }
    private func updateClickRouting(_ point: CGPoint) {
        panel.ignoresMouseEvents = !(hover.isExpanded && widthBridge == nil && motion.isSettled && motion.progress == 1 && geometry.interactiveContains(point))
    }
    /// Pure geometry snapshots: current values use integrated springs, not the last paint.
    private func widthGeometry(ordinary: Bool, endpoint: Bool = false) -> IslandGeometry {
        var value = geometry
        value.ordinaryHoverWidth = ordinary; value.widthPresentation = nil
        value.showsMusicAccessories = (endpoint ? accessoryTarget : (accessoryTarget || accessoryMotion.progress > 0))
            && value.canShowMusicAccessories
        value.musicAccessoryProgress = endpoint ? (accessoryTarget ? 1 : 0) : accessoryMotion.progress
        return value
    }
    private func currentWidthSample() -> IslandWidthSample {
        widthBridge?.sample ?? widthGeometry(ordinary: ordinaryWidthCycle).widthSample(
            progress: motion.progress, velocity: motion.velocity, accessoryVelocity: accessoryMotion.velocity)
    }
    private func retargetWidth(owner: IslandExpansionOwner, eventTime: TimeInterval) {
        let wasOrdinary = ordinaryWidthCycle, hadBridge = widthBridge != nil
        defer {
            if wasOrdinary != ordinaryWidthCycle || hadBridge != (widthBridge != nil) {
                debugState(.width, reason: .bridgeChanged)
            }
        }
        let ordinaryContext = !model.music.isFreshPlaying && !noticeTargetActive
            && presentation.notice == nil && !accessoryTarget && accessoryMotion.isSettled(at: 0)
        if !ordinaryWidthCycle && widthBridge == nil && ordinaryContext && owner == .details
            && motion.isSettled(at: 0) {
            ordinaryWidthCycle = true
            return
        }
        if ordinaryWidthCycle {
            // A fresh playback edge cannot change a still-owned opening. Both
            // maps agree at the full endpoint; switch there without a bridge.
            if owner == .details { return }
            if owner == .idle && ordinaryContext { return }
        } else if widthBridge == nil { return } // All direct music/notice paths stay unchanged.
        let endpoint = widthGeometry(ordinary: false, endpoint: true)
        let target = endpoint.widthSample(progress: motionTargetValue)
        if let widthBridge, widthBridge.target == target { return }
        let current = currentWidthSample(), oldProfile = smokeWidthProfile
        let closed = endpoint.widthSample(progress: 0), full = endpoint.widthSample(progress: 1)
        let lower = min(Double(endpoint.contourFrame.width), closed.width, full.width, current.width, target.width)
        let upper = max(Double(endpoint.contourFrame.width), closed.width, full.width, current.width, target.width)
        let left = min(Double(endpoint.calibratedNotch.midX), closed.center, full.center, current.center, target.center)
        let right = max(Double(endpoint.calibratedNotch.midX), closed.center, full.center, current.center, target.center)
        ordinaryWidthCycle = false
        widthBridge = IslandWidthBridge(from: current, to: target, widthBounds: lower...upper,
            centerBounds: left...right, horizontalBounds: endpoint.motionHorizontalBounds)
        if model.demo, CommandLine.arguments.contains("--ordinary-motion-test"), let bridge = widthBridge {
            widthHandoffSequence &+= 1
            smokeWidthHandoffReceipt = IslandWidthHandoffReceipt(sequence: widthHandoffSequence,
                eventTime: eventTime, integratedTime: lastMotionTime, before: current, after: bridge.sample,
                target: bridge.target, oldProfile: oldProfile, owner: owner)
        }
    }
    private func advanceWidth(elapsed: TimeInterval) {
        widthBridge?.advance(elapsed: elapsed, reduceMotion: reducedMotion)
        if ordinaryWidthCycle && motion.isSettled(at: 1) && model.music.isFreshPlaying {
            ordinaryWidthCycle = false // Same position and first derivative at p=1.
        }
        if ordinaryWidthCycle && motion.isSettled(at: 0) && !accessoryTarget && accessoryMotion.isSettled(at: 0) {
            ordinaryWidthCycle = false
        }
        if let bridge = widthBridge, bridge.isSettled,
           motion.isSettled(at: motionTargetValue), accessoryMotion.isSettled(at: accessoryTarget ? 1 : 0) {
            // The bridge holds its endpoint until the shared map reaches it.
            // Notice dwell/click routing/close drain cannot acknowledge an earlier frame.
            widthBridge = nil
            debugState(.width, reason: .bridgeChanged)
        }
    }
    private func startMotion(reason: DebugCapture.Value = .retarget) {
        guard !stopped else { return }
        cancelCloseDrain()
        let now = CACurrentMediaTime()
        let previousTime = lastMotionTime, previousMotion = motion, previousTarget = motionTargetExpanded
        let elapsed = motionFrames != nil ? max(0, now - lastMotionTime) : 0
        // Consume elapsed time under the previous target before a reversal. A display
        // link may already have projected up to its next frame, so never rewind time.
        if motionFrames != nil, now > lastMotionTime {
            motion.advance(target: motionTargetValue, elapsed: now - lastMotionTime, reduceMotion: reducedMotion)
            accessoryMotion.advance(expanded: accessoryTarget, elapsed: now - lastMotionTime, reduceMotion: reducedMotion)
            advanceWidth(elapsed: now - lastMotionTime)
            lastMotionTime = now
        }
        let integrated = motion
        let owner = expansionOwner
        motionTargetValue = owner.target(compactProgress: owner == .music ? smokeMusicTargetProgress : geometry.updateProgress)
        retargetWidth(owner: owner, eventTime: now)
        switch owner {
        case .music:
            // Notice expiry can return to music at the SAME progress. Retire its
            // content explicitly rather than waiting for an idle endpoint.
            presentation.notice = nil
            presentation.showingDetails = false
            presentation.showingMusic = true
        case .quotaNotice:
            presentation.showingDetails = false
            presentation.showingMusic = false
        case .details: presentation.showingDetails = true
        case .idle: break // Keep the outgoing content through the existing fade.
        }
        motionTargetExpanded = motionTargetValue > 0
        debugState(.ownership, reason: reason)
        if motionSample != nil {
            lastRetarget = IslandMotionRetarget(scheduledTime: previousTime, eventTime: now,
                consumedElapsed: elapsed, before: previousMotion, integrated: integrated,
                previousTarget: previousTarget, nextTarget: motionTargetExpanded)
        }
        if reducedMotion {
            ordinaryWidthCycle = false; widthBridge = nil
            stopMotionFrames()
            motion.advance(target: motionTargetValue, elapsed: 0, reduceMotion: true)
            accessoryMotion.advance(expanded: accessoryTarget, elapsed: 0, reduceMotion: true)
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
        if let testFrameFactory { motionFrames = testFrameFactory(callback) }
        else if motionProfile == .synchronousBaseline { motionFrames = TimerIslandFrames(callback: callback) }
        else if #available(macOS 14.0, *), motionProfile == .adaptive, let view = panel.contentView {
            motionFrames = RecoveringIslandFrames(makePrimary: { DisplayIslandFrames(view: view, callback: $0) },
                presentationAllowed: { [weak self] in self?.permitsMotionRecovery == true }, callback: callback)
        } else { motionFrames = DispatchIslandFrames(callback: callback) }
    }
    private func advanceFrame(to time: TimeInterval) {
        model.debugCapture.recorder.count(.frameCallbacks)
        guard !stopped, let source = motionFrames, time.isFinite, time > lastMotionTime else { return }
        let now = CACurrentMediaTime(), elapsed = max(0, time - lastMotionTime)
        lastMotionTime = max(lastMotionTime, time)
        let accessoryEndpoint: Double = accessoryTarget ? 1 : 0
        let previousProgress = max(motion.progress, abs(accessoryMotion.progress - accessoryEndpoint), widthBridge == nil ? 0 : 1)
        motion.advance(target: motionTargetValue, elapsed: elapsed, reduceMotion: reducedMotion)
        accessoryMotion.advance(expanded: accessoryTarget, elapsed: elapsed, reduceMotion: reducedMotion)
        advanceWidth(elapsed: elapsed)
        let began = CACurrentMediaTime()
        var startedCloseDrain = false
        if drainsClosePresentation, let generation = closeDrain.begin(previousProgress: previousProgress,
            progress: max(motion.progress, abs(accessoryMotion.progress - accessoryEndpoint), widthBridge == nil ? 0 : 1), expanded: motionTargetExpanded, reduceMotion: reducedMotion, now: began) {
            startedCloseDrain = true
            closeGeneration = generation
            closeReceipt = IslandCloseReceipt(requestedAt: began, acknowledgedAt: nil, completedAt: nil, finalDisplayDuration: 0, renderedAt: nil, paintedAt: nil, outcome: .pending)
            let deadline = Timer(timeInterval: closeDrain.timeout, target: self,
                selector: #selector(closeDeadlineReached(_:)), userInfo: generation, repeats: false)
            closeDeadline = deadline; RunLoop.main.add(deadline, forMode: .common)
        }
        apply(progress: motion.progress); updateClickRouting(NSEvent.mouseLocation)
        let duration = CACurrentMediaTime() - began
        if model.debugCapture.recorder.isRecording {
            let capture = model.debugCapture.recorder
            let sourceKind: DebugCapture.Value = source.kind == "view-display-link" ? .displayLink
                : (source.kind.hasPrefix("dispatch-") ? .dispatchTimer : .timer)
            capture.record(.frameCallback, island: capture.identifier(debugToken), sampled: true,
                values: [.scheduledOffsetMs: capture.offsetMilliseconds(time), .elapsedMs: elapsed * 1000,
                    .sourceAgeMs: (now - time) * 1000, .applyMs: duration * 1000, .progress: motion.progress,
                    .target: motionTargetValue, .frameRevision: Double(presentation.frame.revision &- debugFrameRevisionBase)],
                labels: [.source: sourceKind])
        }
        motionSample?(IslandMotionSample(observed: now, scheduled: time, generation: frameGeneration, applyDuration: duration,
            progress: motion.progress, velocity: motion.velocity, expanded: motionTargetExpanded,
            frame: panel.frame, contentBounds: panel.contentView?.bounds ?? .zero,
            viewport: renderedViewport, visible: panel.isVisible, nonKey: !panel.isKeyWindow && !panel.canBecomeKey,
            source: source.kind))
        // A callback may retarget through a diagnostic observer; never retire its new motion.
        guard !stopped, widthBridge == nil, motion.isSettled(at: motionTargetValue), accessoryMotion.isSettled(at: accessoryTarget ? 1 : 0) else { return }
        scheduleNoticeExpiryIfReady()
        if startedCloseDrain { return } // Never acknowledge within the requesting callback.
        if closeDrain.isPending { observeClosePresentation(at: CACurrentMediaTime()) }
        else { stopMotionFrames() }
    }
    private func observeClosePresentation(at time: TimeInterval) {
        guard !stopped, widthBridge == nil, !motionTargetExpanded, accessoryMotion.isSettled(at: accessoryTarget ? 1 : 0), let generation = closeGeneration else { return }
        let expected = geometry.frame(progress: 0)
        let paint = paintStore.latest(), requestedAt = closeReceipt?.requestedAt ?? .infinity
        let freshPaint = paint.map { $0.observed >= requestedAt && $0.frame.progress == 0
            && $0.frame.viewport == expected.size && $0.actualViewport == expected.size } ?? false
        let matches = panel.frame == expected && renderedViewport == expected.size
            && panel.contentView?.bounds == CGRect(origin: .zero, size: expected.size)
            && freshPaint && renderedProgress == 0 && renderedAt >= requestedAt
        let acknowledgedAt = matches ? max(renderedAt, paint?.observed ?? -1) : -1
        let outcome = closeDrain.poll(generation: generation, now: time, renderedAt: acknowledgedAt,
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
                finalDisplayDuration: displayDuration, renderedAt: acknowledgedRender, paintedAt: paint?.observed, outcome: outcome)
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
    var permitsMotionRecovery: Bool {
        guard let view = panel.contentView else { return false }
        return !stopped && panel.isVisible && panel.screen != nil
            && panel.occlusionState.contains(.visible) && !NSApp.isHidden
            && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
    }
    func refreshMotionAvailability() {
        guard !stopped else { return }
        (motionFrames as? RecoveringIslandFrames)?.presentationAvailabilityChanged()
    }
    private func updateMusicPresentation(forceRetarget: Bool = false) {
        guard !stopped else { return }
        let previousOwner = expansionOwner
        if observedPlaybackRevision != model.music.playbackRevision || !model.music.isFreshPlaying {
            resetCrossings(); musicHoverReservation.reset(); observedPlaybackRevision = model.music.playbackRevision
        }
        musicEligible = model.music.isPlayingForPresentation && model.music.lyricsModeEnabled
        if gestureHoverGate.releaseIfLyricsUnavailable(lyricsAvailable: musicEligible) {
            releaseMusicGestureToHover()
        }
        let accessories = model.music.isFreshPlaying && passiveMusicAllowed && geometry.canShowMusicAccessories
        let accessoryChanged = accessoryTarget != accessories
        if accessoryChanged {
            // Integrate the old target before changing it, just like expansion.
            let now = CACurrentMediaTime()
            if motionFrames != nil, now > lastMotionTime {
                motion.advance(target: motionTargetValue, elapsed: now - lastMotionTime, reduceMotion: reducedMotion)
                accessoryMotion.advance(expanded: accessoryTarget, elapsed: now - lastMotionTime, reduceMotion: reducedMotion)
                advanceWidth(elapsed: now - lastMotionTime)
                lastMotionTime = now
            }
            accessoryTarget = accessories
            debugState(.music, reason: .accessoryChanged)
        }
        if forceRetarget || accessoryChanged || expansionOwner != previousOwner || (expansionOwner == .music && motionTargetValue != smokeMusicTargetProgress) {
            startMotion(reason: .musicChanged)
        }
    }

    func setMusicPresentationAllowed(_ allowed: Bool) {
        guard !stopped, passiveMusicAllowed != allowed else { return }
        let previousOwner = expansionOwner
        passiveMusicAllowed = allowed; debugState(.gate, reason: .gateChanged); resetCrossings(); musicHoverReservation.reset(); gestureHoverGate.reset()
        musicGestureNeedsCorridorExit = false; musicHoverReservation.resetDwell()
        updateMusicPresentation(forceRetarget: expansionOwner != previousOwner)
    }
    @discardableResult func showRefreshNotice(_ notice: RefreshNotice) -> Bool {
        guard !stopped, notice.isEligible, model.refreshNoticesEnabled, !hover.isExpanded, placementIsValid else { return false }
        if presentation.notice?.id == notice.id && noticeTargetActive { return true }
        cancelNoticeTimers(); resetCrossings(); musicHoverReservation.reset(); musicGestureNeedsCorridorExit = false
        // Every new notice, including replacement, acknowledges its own paint revision.
        noticePaintRequiredAfter = CACurrentMediaTime()
        presentation.notice = notice; presentation.showingDetails = false; noticeTargetActive = true
        // Watch opening as well as settled rendering: a hidden/stalled display
        // driver must not leave a notification owning input indefinitely.
        let readinessStarted = CACurrentMediaTime()
        noticeReadyWaitStarted = readinessStarted
        noticeReadinessDeadline = readinessStarted + 10
        let timer = Timer(timeInterval: 0.02, target: self,
            selector: #selector(checkNoticeReadiness(_:)), userInfo: nil, repeats: true)
        noticeReadiness = timer; RunLoop.main.add(timer, forMode: .common)
        startMotion(reason: .noticeShown); panel.ignoresMouseEvents = true
        return true
    }
    func dismissRefreshNotice() {
        guard presentation.notice != nil else { return }
        cancelNoticeTimers(); noticeTargetActive = false
        if !hover.isExpanded { startMotion(reason: .noticeDismissed) }
    }
    private func cancelNoticeTimers() {
        noticeExpiry?.invalidate(); noticeExpiry = nil
        noticeReadiness?.invalidate(); noticeReadiness = nil
        noticeReadyWaitStarted = nil; noticeReadinessDeadline = nil; smokeNoticeArmedAt = nil; smokeNoticePaintReadyAt = nil
    }
    private func scheduleNoticeExpiryIfReady() {
        guard !stopped, noticeTargetActive, placementIsValid, panel.isVisible,
              let notice = presentation.notice, !hover.isExpanded,
              noticeExpiry == nil, widthBridge == nil, motion.isSettled(at: geometry.updateProgress) else { return }
        let now = CACurrentMediaTime(), expected = geometry.frame(progress: geometry.updateProgress)
        if now >= smokeNoticeReadinessNotBefore,
           let paint = paintStore.latest(), paint.observed >= noticePaintRequiredAfter,
           paint.frame.noticeID == notice.id, paint.frame.progress == geometry.updateProgress,
           paint.frame.viewport == expected.size, paint.actualViewport == expected.size,
           panel.frame == expected, renderedViewport == expected.size,
           renderedProgress == geometry.updateProgress, renderedAt >= noticePaintRequiredAfter {
            noticeReadiness?.invalidate(); noticeReadiness = nil; noticeReadyWaitStarted = nil; noticeReadinessDeadline = nil
            smokeNoticePaintReadyAt = paint.observed; smokeNoticeArmedAt = now
            let timer = Timer(timeInterval: notice.holdDuration, target: self,
                selector: #selector(expireNotice(_:)), userInfo: nil, repeats: false)
            noticeExpiry = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    @objc private func checkNoticeReadiness(_ sender: Timer) {
        guard !stopped, sender === noticeReadiness else { return }
        guard noticeTargetActive, !hover.isExpanded, presentation.notice != nil else { cancelNoticeTimers(); return }
        guard placementIsValid, panel.isVisible else { dismissRefreshNotice(); return }
        // Slow layout/paint must not turn a six-second notification into a flash.
        // Only an actual settled paint starts dwell; retry rendering without
        // fabricating readiness or expiring content before it becomes readable.
        scheduleNoticeExpiryIfReady()
        guard sender === noticeReadiness else { return }
        // A truly unavailable renderer must not reserve input forever. This is
        // a failed presentation, never reported as a completed readable hold.
        if let deadline = noticeReadinessDeadline, CACurrentMediaTime() >= deadline {
            SmokeDiagnostics.mark("notice presentation failed: no stable paint within 10 seconds")
            dismissRefreshNotice(); return
        }
        if let began = noticeReadyWaitStarted, CACurrentMediaTime() - began > 0.25 {
            SmokeDiagnostics.mark("notice paint readiness delayed; requesting display")
            noticeReadyWaitStarted = CACurrentMediaTime()
            panel.contentView?.needsDisplay = true
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
        }
    }
    @objc private func expireNotice(_ sender: Timer) {
        guard !stopped, sender === noticeExpiry else { return }
        noticeExpiry = nil
        guard !hover.isExpanded else { return }
        // Retain the text during the closing fade; a separate flag chooses the idle target.
        noticeTargetActive = false
        startMotion(reason: .noticeExpired)
    }
    func collapse() {
        guard !stopped else { return }
        cancelNoticeTimers(); noticeTargetActive = false
        hover.reset(); resetCrossings(); musicHoverReservation.reset(); gestureHoverGate.reset()
        musicGestureNeedsCorridorExit = false; musicHoverReservation.resetDwell()
        panel.ignoresMouseEvents = true; startMotion(reason: .collapse)
    }
    func stop() {
        guard !stopped else { return }
        debugState(.lifecycle, reason: .stopped)
        stopped = true; ordinaryWidthCycle = false; widthBridge = nil
        resetCrossings(); musicHoverReservation.reset(); gestureHoverGate.reset()
        musicGestureNeedsCorridorExit = false; musicHoverReservation.resetDwell()
        smokePolledPointer = nil
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor); self.localPointerMonitor = nil }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor); self.globalPointerMonitor = nil }
        musicSubscription?.cancel(); musicSubscription = nil
        cancelNoticeTimers()
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
    /// Synthetic pointer position follows the corrected visible contour, including
    /// negative depth calibration. The raw camera exclusion is not a hover target.
    private var smokeInteriorPoint: CGPoint {
        let frame = geometry.frame(progress: motion.progress)
        let contour = geometry.contourRect(progress: motion.progress)
        return CGPoint(x: frame.minX + contour.midX, y: frame.maxY - contour.maxY + 1)
    }
    @discardableResult
    func beginSmokeExpansion() -> Bool {
        guard !stopped else { return false }
        let point = smokeInteriorPoint
        let contained = geometry.hoverContains(point, progress: motion.progress)
        updatePointer(point, now: 0, buttonDownOverride: false); updatePointer(point, now: 0.13, buttonDownOverride: false)
        SmokeDiagnostics.mark("synthetic expansion contained=\(contained) targetExpanded=\(hover.isExpanded)")
        return contained && hover.isExpanded
    }
    func smokePointer(at point: CGPoint, now: TimeInterval, buttonDown: Bool = false) {
        guard model.demo && (CommandLine.arguments.contains("--motion-test") || CommandLine.arguments.contains("--music-test") || CommandLine.arguments.contains("--update-test")) else { return }
        updatePointer(point, now: now, buttonDownOverride: buttonDown)
    }
    func smokePointer(inside: Bool, now: TimeInterval) {
        let point = inside ? smokeInteriorPoint
            : CGPoint(x: geometry.screen.minX - 10, y: geometry.screen.minY - 10)
        updatePointer(point, now: now, buttonDownOverride: false)
    }
    /// Location-only fixture seam for the actual polling path. This does not
    /// establish delivery through a system global monitor or move the cursor.
    /// Synthetic cache-gate diagnosis only; no normal input trace or mutation.
    func smokeMusicInputState(at point: CGPoint) -> [String: Any]? {
        guard model.demo, CommandLine.arguments.contains("--music-test"),
              CommandLine.arguments.contains("--music-cache-test") else { return nil }
        func finite(_ value: TimeInterval) -> Any { value.isFinite ? value as Any : NSNull() }
        let anchor: Any = musicHoverReservation.stationaryAnchor.map { [Double($0.x), Double($0.y)] as Any } ?? NSNull()
        return ["gestureSuppressed": gestureHoverGate.isSuppressing,
            "needsCorridorExit": musicGestureNeedsCorridorExit,
            "eventTracking": crossing.isTracking, "eventReserves": crossing.reservesPointer,
            "eventLocked": crossing.isLocked, "pollTracking": fallbackCrossing.isTracking,
            "pollReserves": fallbackCrossing.reservesPointer, "pollLocked": fallbackCrossing.isLocked,
            "hoverExpanded": hover.isExpanded, "insideCurrentHover": currentHoverContains(point),
            "hoverAnchor": anchor,
            "lastEventTime": finite(lastEventTime), "lastEventDelivery": finite(lastEventDelivery),
            "lastAppliedGestureTime": finite(lastAppliedGestureTime), "lastPollTime": finite(lastPollTime),
            "buttonStateTime": finite(buttonStateTime), "buttons": eventButtons.sorted()]
    }
    func smokeSetPolledPointer(_ point: CGPoint?) {
        guard model.demo, CommandLine.arguments.contains("--music-test"), !stopped else { return }
        if let point, !point.x.isFinite || !point.y.isFinite { return }
        smokePolledPointer = point
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
    var paintReceipt: IslandPaintReceipt? { paintStore.latest() }
    func smokeDelayNoticeReadiness(seconds: TimeInterval) {
        guard model.demo, CommandLine.arguments.contains("--update-test") else { return }
        smokeNoticeReadinessNotBefore = CACurrentMediaTime() + max(0, seconds)
    }
    var smokeNoticeVisible: Bool { presentation.notice != nil }
    var smokeLyricsSelected: Bool { model.music.lyricsModeEnabled }
    var smokeMusicGestureCorridor: CGRect { geometry.musicGestureCorridor }
    var smokeMusicAccessoriesVisible: Bool { geometry.showsMusicAccessories }
    @discardableResult func smokeMusicGesture(openLyrics: Bool) -> Bool {
        guard model.demo, CommandLine.arguments.contains("--music-test") else { return false }
        let corridor = geometry.musicGestureCorridor
        let now = ProcessInfo.processInfo.systemUptime
        // Use adjacent horizontal entry/exit, just like a real mouse swipe.
        // The post-gesture ownership gate must prevent accidental hover promotion.
        let outside = CGPoint(x: openLyrics ? corridor.minX - 12 : corridor.maxX + 12, y: corridor.midY)
        updatePointer(outside, now: now, buttonDownOverride: false)
        let fractions: [CGFloat] = openLyrics ? [0.02, 0.25, 0.52, 0.75, 0.98] : [0.98, 0.75, 0.48, 0.25, 0.02]
        for (index, fraction) in fractions.enumerated() {
            updatePointer(CGPoint(x: corridor.minX + corridor.width * fraction, y: corridor.midY), now: now + Double(index + 1) * 0.035, buttonDownOverride: false)
        }
        let exit = CGPoint(x: openLyrics ? corridor.maxX + 5 : corridor.minX - 5, y: corridor.midY)
        updatePointer(exit, now: now + 0.21, buttonDownOverride: false)
        return model.music.lyricsModeEnabled == openLyrics
    }
    var smokeMusicVisible: Bool { presentation.showingMusic }
    var smokeMusicTargetActive: Bool { expansionOwner == .music }
    var smokeMusicPresentationRevision: UInt64 { model.music.presentationRevision }
    var smokeMusicTargetProgress: Double {
        geometry.musicProgress(contentHeight: model.music.previewContentHeight(width: geometry.compactContentWidth))
    }
    var smokeExpansionOwner: IslandExpansionOwner { expansionOwner }
    var smokeNoticeID: UUID? { presentation.notice?.id }
    func verifyRetiredNoticeIsInert() -> Bool {
        guard CommandLine.arguments.contains("--update-test"), let timer = noticeExpiry else { return false }
        let before = (motion.progress, motion.velocity, panel.frame, presentation.notice?.id)
        stop(); expireNotice(timer)
        return smokeStopped && noticeExpiry == nil && motion.progress == before.0
            && motion.velocity == before.1 && panel.frame == before.2 && presentation.notice?.id == before.3
    }
    var smokeNoticeTargetActive: Bool { noticeTargetActive }
    // Read-only fixture snapshots: do not expose a mutable Timer or add any
    // recurring work to the production notification/animation paths.
    var smokeMusicAccessoryTargetActive: Bool { accessoryTarget }
    var smokeMusicStationaryRadius: CGFloat { IslandMusicHoverReservation.stationaryRadius }
    func smokePointerHoverDecision(at eventTime: TimeInterval, kind: String) ->
        (timestamp: TimeInterval, inside: Bool, expandedBefore: Bool, expandedAfter: Bool)? {
        guard model.demo, CommandLine.arguments.contains("--pointer-ingress-test"),
              let decision = smokePointerIngress.last(where: { $0.timestamp == eventTime && $0.kind == kind })?.hoverDecision else { return nil }
        return (decision.timestamp, decision.inside, decision.expandedBefore, decision.expandedAfter)
    }
    var smokeNoticeExpiry: (identity: ObjectIdentifier, fireDate: Date, isValid: Bool)? {
        guard model.demo, CommandLine.arguments.contains("--music-test"), let noticeExpiry else { return nil }
        return (ObjectIdentifier(noticeExpiry), noticeExpiry.fireDate, noticeExpiry.isValid)
    }
    var smokeTargetProgress: Double { motionTargetValue }
    var smokeProgress: Double { motion.progress }
    var smokeVelocity: Double { motion.velocity }
    var smokeWidthProfile: String { widthBridge != nil ? "ordinary-handoff" : (ordinaryWidthCycle ? "ordinary-v100" : "shared-v103") }
    var smokeWidthSample: IslandWidthSample { currentWidthSample() }
    var smokeWidthBridgeTarget: IslandWidthSample? { widthBridge?.target }
    var smokeWidthBridgeElapsed: Double? { widthBridge?.elapsed }
    var smokeHasPendingGeometry: Bool { pendingGeometry != nil }
    var smokeHoverSnapshotProgress: Double { currentHoverProgress }
    func smokeCurrentHoverContains(_ point: CGPoint) -> Bool { currentHoverContains(point) }
    var smokeAccessoryProgress: Double { accessoryMotion.progress }
    var smokeAccessoryVelocity: Double { accessoryMotion.velocity }
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
            && CGRect(x: 0, y: 0, width: geometry.detailContentWidth, height: contentHeight).contains(quitFrame)
        let frame = geometry.frame(progress: 1)
        let originX = frame.minX + geometry.contourRect(progress: 1).midX - geometry.detailContentWidth / 2
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
// Only the current full Music fixture consumes these read-only probes. Older
// production panels overlaid with the same harness need not conform.
extension IslandPanelController: MusicNoticePauseProbeProviding, MusicPointerHoverProbeProviding {}
#endif
