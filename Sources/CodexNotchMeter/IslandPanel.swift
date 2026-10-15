#if os(macOS)
import AppKit
import SwiftUI
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
}

struct IslandSilhouette: Shape {
    let progress: Double
    func path(in rect: CGRect) -> Path {
        let shoulder = CGFloat(progress) * 12
        let radius = min(12 + CGFloat(progress) * 12, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: shoulder, y: shoulder), control: CGPoint(x: shoulder, y: 0))
        path.addLine(to: CGPoint(x: shoulder, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: shoulder + radius, y: rect.height), control: CGPoint(x: shoulder, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - shoulder - radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: rect.width - shoulder, y: rect.height - radius), control: CGPoint(x: rect.width - shoulder, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - shoulder, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: 0), control: CGPoint(x: rect.width - shoulder, y: 0))
        path.closeSubpath()
        return path
    }
}

@MainActor
private struct IslandRootView: View {
    @ObservedObject var model: MeterModel
    @ObservedObject var presentation: IslandPresentation
    let geometry: IslandGeometry
    let refresh: () -> Void
    let settings: () -> Void
    let quit: () -> Void
    let quitFrameChanged: (CGRect) -> Void
    let viewportChanged: (CGSize) -> Void
    var body: some View {
        let p = presentation.progress
        GeometryReader { viewport in
            Color.clear
                .overlay { IslandSilhouette(progress: p).fill(.black.opacity(min(1, p * 3))) }
                .overlay(alignment: .top) {
                    RailView(model: model, hovered: { _ in })
                    .frame(width: geometry.collapsedSize.width, height: geometry.collapsedSize.height)
                    .opacity(max(0, 1 - p * 4))
                    .accessibilityHidden(p > 0.1)
                }
                .overlay(alignment: .top) {
                    // Opacity-zero fixed-height content MUST NOT size the collapsed root.
                    if p > 0 {
                        DetailView(model: model, embedded: true, embeddedHeight: geometry.expandedSize.height - geometry.notch.height - 8, quitFrameChanged: quitFrameChanged, hovered: { _ in }, refresh: refresh, settings: settings, quit: quit)
                            .padding(.top, geometry.notch.height + 8)
                            .opacity(min(1, max(0, (p - 0.35) / 0.5)))
                            .allowsHitTesting(p == 1)
                            .accessibilityHidden(p < 1)
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                .clipShape(IslandSilhouette(progress: p))
                .onAppear { viewportChanged(viewport.size) }
                .onChange(of: viewport.size) { viewportChanged($0) }
            }
        .ignoresSafeArea(.all)
        // Native panel frame and this shape share one spring; no implicit size animation.
        .transaction { $0.animation = nil }
    }
}

@MainActor
final class IslandPanelController: NSObject {
    let geometry: IslandGeometry
    let panel: TopEdgePanel
    private let presentation = IslandPresentation()
    private var hover = IslandHoverState()
    private var motion = IslandMotion()
    private var pointerTimer: Timer?
    private var motionTimer: Timer?
    private var lastMotionTime = ProcessInfo.processInfo.systemUptime
    private let reducedMotionOverride: Bool?
    private var reducedMotion: Bool { reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var placementIsValid = true
    private var stopped = false
    private var quitFrame: CGRect = .zero
    private(set) var renderedViewport: CGSize = .zero
    private let hovered: () -> Void
    private let activityChanged: () -> Void

    init(model: MeterModel, geometry: IslandGeometry, startPolling: Bool = true, reducedMotionOverride: Bool? = nil,
         activityChanged: @escaping () -> Void = {}, hovered: @escaping () -> Void, refresh: @escaping () -> Void,
         settings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.geometry = geometry; self.hovered = hovered; self.activityChanged = activityChanged; self.reducedMotionOverride = reducedMotionOverride
        panel = TopEdgePanel(contentRect: geometry.frame(progress: 0), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.animationBehavior = .none; panel.ignoresMouseEvents = true
        let hosting = IslandHostingView(rootView: IslandRootView(model: model, presentation: presentation,
            geometry: geometry, refresh: refresh, settings: settings, quit: quit,
            quitFrameChanged: { [weak self] in self?.quitFrame = $0 },
            viewportChanged: { [weak self] in self?.renderedViewport = $0 }))
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
    private func apply(progress: Double) {
        guard !stopped else { return }
        let hadDetails = displaysColoredDetails
        presentation.progress = progress
        if hadDetails != displaysColoredDetails { activityChanged() }
        let expected = geometry.frame(progress: progress)
        panel.setFrame(expected, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        if abs(panel.frame.maxY - geometry.screen.maxY) > 0.5 || abs(panel.frame.width - expected.width) > 0.5 {
            placementIsValid = false
            panel.orderOut(nil)
        }
    }
    func setContourTestProgress(_ progress: Double) {
        guard CommandLine.arguments.contains("--contour-test") else { return }
        apply(progress: progress)
    }
    @objc private func pollPointer(_ timer: Timer) {
        guard !stopped, placementIsValid else { return }
        updatePointer(NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime)
    }
    private func updatePointer(_ point: CGPoint, now: TimeInterval) {
        let before = hover.isExpanded
        hover.update(inside: geometry.hoverContains(point, progress: motion.progress), now: now)
        if hover.isExpanded != before {
            if hover.isExpanded { hovered() }
            startMotion()
        }
        updateClickRouting(point)
    }
    private func updateClickRouting(_ point: CGPoint) {
        panel.ignoresMouseEvents = !(hover.isExpanded && motion.isSettled && motion.progress == 1 && geometry.interactiveContains(point))
    }
    private func startMotion() {
        if reducedMotion {
            motion.advance(expanded: hover.isExpanded, elapsed: 0, reduceMotion: true)
            apply(progress: motion.progress); updateClickRouting(NSEvent.mouseLocation)
            return
        }
        guard motionTimer == nil else { return }
        lastMotionTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(animate(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common); motionTimer = timer
    }
    @objc private func animate(_ timer: Timer) {
        let now = ProcessInfo.processInfo.systemUptime
        motion.advance(expanded: hover.isExpanded, elapsed: now - lastMotionTime, reduceMotion: reducedMotion)
        lastMotionTime = now
        apply(progress: motion.progress); updateClickRouting(NSEvent.mouseLocation)
        if motion.isSettled { motionTimer?.invalidate(); motionTimer = nil }
    }
    func collapse() {
        hover.reset(); panel.ignoresMouseEvents = true; startMotion()
    }
    func stop() {
        stopped = true
        pointerTimer?.invalidate(); pointerTimer = nil
        motionTimer?.invalidate(); motionTimer = nil
        panel.ignoresMouseEvents = true; panel.close()
    }
    /// Real AppKit panel checks with synthetic geometry/data; never a physical-notch claim.
    func verifyNativeGeometry() -> Bool {
        let keyWindow = NSApp.keyWindow
        var valid = true
        for progress in [0.0, 0.2, 0.65, 1, 0.7, 0.35, 0.8, 1, 0] {
            apply(progress: progress)
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
    func smokePointer(inside: Bool, now: TimeInterval) {
        let point = inside ? CGPoint(x: geometry.notch.midX, y: geometry.screen.maxY - geometry.notch.height - 2)
            : CGPoint(x: geometry.screen.minX - 10, y: geometry.screen.minY - 10)
        updatePointer(point, now: now)
    }
    var displaysColoredDetails: Bool { presentation.progress > 0.35 }
    var smokeProgress: Double { motion.progress }
    var smokeTargetExpanded: Bool { hover.isExpanded }
    var smokeStopped: Bool { stopped && pointerTimer == nil && motionTimer == nil && !panel.isVisible }
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
    var smokeExpanded: Bool {
        let contentHeight = geometry.expandedSize.height - geometry.notch.height - 8
        let quitVisible = quitFrame.width > 0 && quitFrame.height >= 20
            && CGRect(x: 0, y: 0, width: 340, height: contentHeight).contains(quitFrame)
        let frame = geometry.frame(progress: 1)
        let originX = frame.midX - 170
        let contentTop = frame.maxY - geometry.notch.height - 8
        let clickPoints = [
            CGPoint(x: originX + quitFrame.minX + 3, y: contentTop - quitFrame.minY - 3),
            CGPoint(x: originX + quitFrame.maxX - 3, y: contentTop - quitFrame.maxY + 3),
            CGPoint(x: originX + quitFrame.midX, y: contentTop - quitFrame.midY)
        ]
        let clickable = clickPoints.allSatisfy(geometry.interactiveContains)
        let rendered = verifyRenderedTopEdge()
        SmokeDiagnostics.mark("expanded progress=\(motion.progress) settled=\(motion.isSettled) visible=\(panel.isVisible) quit=\(quitFrame) contentHeight=\(contentHeight) quitVisible=\(quitVisible) clickable=\(clickable)")
        SmokeDiagnostics.mark(quitVisible && clickable ? "visible Quit layout and routing bounds passed" : "visible Quit layout or routing bounds failed")
        return motion.progress == 1 && motion.isSettled && panel.isVisible && quitVisible && clickable && rendered
    }
}
#endif
