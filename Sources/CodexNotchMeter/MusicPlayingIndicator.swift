#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

/// A playback-state ornament, not a measured audio spectrum. The caller must
/// include fresh playback and presentation visibility in `active`.
@MainActor
struct MusicPlayingIndicator: NSViewRepresentable {
    let active: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> MusicPlayingIndicatorView {
        let view = MusicPlayingIndicatorView(frame: .zero)
        view.configure(active: active, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: MusicPlayingIndicatorView, context: Context) {
        view.configure(active: active, reduceMotion: reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MusicPlayingIndicatorView,
                     context: Context) -> CGSize? { MusicPlayingIndicatorView.iconSize }

    static func dismantleNSView(_ view: MusicPlayingIndicatorView, coordinator: ()) {
        view.dismantle()
    }
}

/// Only three CALayer transforms animate. There is no display-link, timer,
/// SwiftUI animation transaction, published frame state, or window layout loop.
@MainActor
final class MusicPlayingIndicatorView: NSView {
    static let iconSize = CGSize(width: 20, height: 20)
    fileprivate static let animationKey = "music.playing.scale"
    fileprivate static let values: [[Double]] = [
        [0.48, 0.78, 0.40, 0.64, 0.48],
        [0.82, 0.48, 0.74, 0.56, 0.82],
        [0.58, 0.38, 0.72, 0.46, 0.58]
    ]
    private let bars = (0..<3).map { _ in CALayer() }
    private var active = false
    private var reduceMotion = false
    private var animating = false
    private var windowClosing = false
    private var dismantled = false
    fileprivate private(set) var animationStartCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        setAccessibilityElement(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 2.5, height: 14)
            bar.cornerRadius = 1.25
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
            bar.transform = CATransform3DMakeScale(1, CGFloat(Self.values[index][0]), 1)
            root.addSublayer(bar)
        }
        CATransaction.commit()
        positionBars()
    }

    required init?(coder: NSCoder) { return nil }
    override var intrinsicContentSize: NSSize { Self.iconSize }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(active: Bool, reduceMotion: Bool) {
        guard !dismantled else { return }
        self.active = active
        self.reduceMotion = reduceMotion
        reconcileAnimation()
    }

    override func layout() {
        super.layout()
        positionBars()
        reconcileAnimation()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopAnimation()
        NotificationCenter.default.removeObserver(self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        windowClosing = false
        guard !dismantled, let window else { stopAnimation(); return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)),
                name: name, object: window)
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)),
                name: name, object: NSApp)
        }
        positionBars()
        reconcileAnimation()
    }

    override func viewDidHide() { super.viewDidHide(); stopAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcileAnimation() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); positionBars() }

    @objc private func visibilityChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification { windowClosing = true }
        reconcileAnimation()
    }

    private func positionBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 1
        layer?.contentsScale = scale
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: bounds.midX + CGFloat(index - 1) * 5, y: bounds.midY)
            bar.contentsScale = scale
        }
        CATransaction.commit()
    }

    private func reconcileAnimation() {
        let visible = window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        guard active, !reduceMotion, !dismantled, !windowClosing,
              !isHiddenOrHasHiddenAncestor, !NSApp.isHidden, visible else {
            stopAnimation(); return
        }
        guard !animating else { return }
        animating = true
        animationStartCount += 1
        for (index, bar) in bars.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = Self.values[index].map { NSNumber(value: $0) }
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.duration = 1.6
            animation.calculationMode = .linear
            animation.timingFunctions = (0..<4).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
            animation.repeatCount = .infinity
            bar.add(animation, forKey: Self.animationKey)
        }
    }

    private func stopAnimation() {
        guard animating else { return }
        animating = false
        // The model transforms remain the same static pose throughout playback;
        // removing the presentation animation restores that pose immediately.
        for bar in bars { bar.removeAnimation(forKey: Self.animationKey) }
    }

    func dismantle() {
        dismantled = true
        active = false
        NotificationCenter.default.removeObserver(self)
        stopAnimation()
    }

    fileprivate var animationKeys: [[String]] { bars.map { $0.animationKeys() ?? [] } }
    fileprivate var presentationScales: [Double]? {
        let values = bars.compactMap { $0.presentation().map { Double($0.transform.m22) } }
        return values.count == bars.count ? values : nil
    }
    fileprivate var modelScales: [Double] { bars.map { Double($0.transform.m22) } }
    fileprivate var animations: [CAKeyframeAnimation] {
        bars.compactMap { $0.animation(forKey: Self.animationKey) as? CAKeyframeAnimation }
    }
}

/// Bounded native evidence for the synthetic cache gate. Captures are rendered
/// from the actual own-window presentation layer after real run-loop time, not
/// from hand-selected animation times. This does not measure GPU scanout or FPS.
@MainActor
enum MusicPlayingIndicatorVerification {
    private struct Failure: LocalizedError, CustomStringConvertible {
        let label: String
        var errorDescription: String? { label }
        var description: String { label }
    }
    private struct Capture {
        let pixels: Data
        let png: Data
        let width: Int
        let height: Int
    }

    static func run(outputDirectory: URL) async throws -> [String: Any] {
        try require(CommandLine.arguments.contains("--music-test")
            && CommandLine.arguments.contains("--music-cache-test"), "synthetic-cache-only")
        let began = CACurrentMediaTime()
        let deadline = began + 1.9
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSPanel(contentRect: NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 40, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.backgroundColor = .black
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        let view = MusicPlayingIndicatorView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        host.addSubview(view)
        window.contentView = host
        let originalKeyWindow = NSApp.keyWindow
        defer { view.dismantle(); window.orderOut(nil); window.contentView = nil; window.close() }
        view.configure(active: true, reduceMotion: false)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await wait(deadline, label: "native-visible-start") { running(view) }
        try require(!window.isKeyWindow && NSApp.keyWindow === originalKeyWindow
            && view.frame.size == MusicPlayingIndicatorView.iconSize, "fixed-size-non-key")
        let starts = view.animationStartCount
        for _ in 0..<100 { view.configure(active: true, reduceMotion: false) }
        try require(view.animationStartCount == starts, "unchanged-input-does-not-restart")
        for index in 0..<100 {
            view.setFrameOrigin(NSPoint(x: index.isMultiple(of: 2) ? 10 : 10.25, y: 10))
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        view.setFrameOrigin(NSPoint(x: 10, y: 10))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        try require(view.animationStartCount == starts && running(view)
            && view.frame == NSRect(x: 10, y: 10, width: 20, height: 20), "layout-does-not-restart")
        let animations = view.animations
        try require(animations.count == 3 && animations.allSatisfy {
            let values = $0.values as? [NSNumber]
            return $0.keyPath == "transform.scale.y" && $0.duration == 1.6
                && $0.repeatCount.isInfinite && values?.count == 5 && values?.first == values?.last
                && $0.keyTimes == [0, 0.25, 0.5, 0.75, 1]
        }, "compositor-keyframes-and-loop-endpoints")

        try await Task.sleep(nanoseconds: 140_000_000)
        let timeA = CACurrentMediaTime()
        let scalesA = try scales(view)
        let playingA = try capture(host, scale: window.backingScaleFactor)
        try await Task.sleep(nanoseconds: 220_000_000)
        let timeB = CACurrentMediaTime()
        let scalesB = try scales(view)
        let playingB = try capture(host, scale: window.backingScaleFactor)
        let changedBars = zip(scalesA, scalesB).filter { abs($0.0 - $0.1) > 0.01 }.count
        let changedBytes = zip(playingA.pixels, playingB.pixels).filter { $0.0 != $0.1 }.count
        try require(changedBars == 3 && changedBytes > 0 && timeB > timeA,
            "three-real-presentation-bars-and-pixels-advance")

        view.configure(active: false, reduceMotion: false)
        try require(stopped(view), "pause-removes-animations")
        try await Task.sleep(nanoseconds: 40_000_000)
        let paused = try capture(host, scale: window.backingScaleFactor)
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(try capture(host, scale: window.backingScaleFactor).pixels == paused.pixels,
            "paused-pixels-stable")
        try require(resting(view), "pause-restores-model-pose")

        view.configure(active: true, reduceMotion: false)
        try await wait(deadline, label: "resume-before-reduce-motion") { running(view) }
        try await Task.sleep(nanoseconds: 30_000_000)
        view.configure(active: true, reduceMotion: true)
        try require(stopped(view), "reduce-motion-removes-animations")
        try await Task.sleep(nanoseconds: 40_000_000)
        let reduced = try capture(host, scale: window.backingScaleFactor)
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(try capture(host, scale: window.backingScaleFactor).pixels == reduced.pixels
            && reduced.pixels == paused.pixels && resting(view), "reduce-motion-static-pose")

        view.configure(active: true, reduceMotion: false)
        try await wait(deadline, label: "resume-after-reduce-motion") { running(view) }
        host.isHidden = true
        try require(stopped(view), "hidden-ancestor-removes-animations")
        host.isHidden = false
        try await wait(deadline, label: "unhide-resumes") { running(view) }
        window.orderOut(nil)
        try await wait(deadline, label: "order-out-removes-animations") { !window.isVisible && stopped(view) }
        window.orderFrontRegardless()
        try await wait(deadline, label: "order-front-resumes") { running(view) }
        view.removeFromSuperview()
        try require(stopped(view), "detach-removes-animations")
        host.addSubview(view)
        try await wait(deadline, label: "reattach-resumes") { running(view) }
        view.dismantle()
        view.configure(active: true, reduceMotion: false)
        try require(stopped(view), "dismantled-view-cannot-restart")
        try require(CACurrentMediaTime() < deadline, "native-evidence-bounded")

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let captures = [("playing-a", playingA), ("playing-b", playingB), ("paused", paused), ("reduced-motion", reduced)]
        for (name, image) in captures {
            try image.png.write(to: outputDirectory.appendingPathComponent("perimeter-indicator-\(name).png"), options: .atomic)
        }
        let elapsed = CACurrentMediaTime() - began
        try require(elapsed < 1.9, "native-capture-and-export-bounded")
        return ["schema": 1, "synthetic": true, "ownPresentationLayerPixels": true, "scanout": false,
            "elapsed": elapsed, "sampleTimes": [timeA - began, timeB - began],
            "scalesA": scalesA, "scalesB": scalesB, "changedBars": changedBars, "changedBytes": changedBytes,
            "animationKey": MusicPlayingIndicatorView.animationKey, "barCount": 3,
            "iconWidth": 20, "iconHeight": 20, "pixelWidth": playingA.width, "pixelHeight": playingA.height,
            "backingScale": Double(window.backingScaleFactor), "unchangedUpdates": 100, "unchangedLayouts": 100,
            "loopEndpointsMatch": true, "pausedStable": true, "reduceMotionStable": true,
            "hiddenAncestorStopped": true, "orderedOutStopped": true, "detachedStopped": true,
            "dismantledStopped": true, "pngs": captures.map { "perimeter-indicator-\($0.0).png" }]
    }

    private static func require(_ value: Bool, _ label: String) throws {
        if !value { throw Failure(label: "music-indicator-" + label) }
    }

    private static func wait(_ deadline: TimeInterval, label: String, _ condition: () -> Bool) async throws {
        while !condition() {
            try require(CACurrentMediaTime() < deadline, label)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func running(_ view: MusicPlayingIndicatorView) -> Bool {
        view.animationKeys.allSatisfy { $0 == [MusicPlayingIndicatorView.animationKey] }
    }
    private static func stopped(_ view: MusicPlayingIndicatorView) -> Bool { view.animationKeys.allSatisfy(\.isEmpty) }
    private static func resting(_ view: MusicPlayingIndicatorView) -> Bool {
        guard let presentation = view.presentationScales else { return false }
        return zip(presentation, view.modelScales).allSatisfy { abs($0.0 - $0.1) < 0.0001 }
    }
    private static func scales(_ view: MusicPlayingIndicatorView) throws -> [Double] {
        guard let values = view.presentationScales, values.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }) else {
            throw Failure(label: "music-indicator-missing-native-presentation")
        }
        return values
    }

    private static func capture(_ host: NSView, scale: CGFloat) throws -> Capture {
        let width = Int((host.bounds.width * scale).rounded()), height = Int((host.bounds.height * scale).rounded())
        guard width > 0, height > 0, let presentation = host.layer?.presentation(),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(label: "music-indicator-native-capture-context")
        }
        context.scaleBy(x: scale, y: scale)
        presentation.render(in: context)
        guard let pointer = context.data, let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(label: "music-indicator-native-capture-png")
        }
        return Capture(pixels: Data(bytes: pointer, count: width * height * 4), png: png, width: width, height: height)
    }
}
#endif
