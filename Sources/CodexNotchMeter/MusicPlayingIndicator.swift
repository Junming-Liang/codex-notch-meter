#if os(macOS)
import AppKit
import CryptoKit
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
    fileprivate var barKeyframeAnimations: [CAKeyframeAnimation] {
        bars.compactMap { $0.animation(forKey: Self.animationKey) as? CAKeyframeAnimation }
    }
}

/// Bounded native evidence for the synthetic cache gate. Captures are rendered
/// from actual own-window presentation layers over a complete animation period.
/// No animation time is forced. This does not measure GPU scanout or FPS.
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
        var pngSHA256: String { SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() }
    }
    private struct Sample {
        let time: TimeInterval
        let scales: [Double]
        let image: Capture
        let receipt: [String: Any]
    }

    // Fixture-only diagnostics. Store raw clocks in a bounded buffer; do not
    // encode, print, add a wake source, or change scheduling while observing.
    private struct NativeWake: Sendable {
        let armed: TimeInterval
        let fired: TimeInterval
    }
    @MainActor private final class WakeTrace {
        static let capacity = 256
        private struct Row {
            let stage: String
            let target: TimeInterval
            let interval: TimeInterval
            let wake: NativeWake
            let resumed: TimeInterval
        }
        private var rows: [Row] = []
        private(set) var dropped = 0
        func record(stage: String, target: TimeInterval, interval: TimeInterval,
                    wake: NativeWake, resumed: TimeInterval) {
            guard rows.count < Self.capacity else { dropped += 1; return }
            rows.append(Row(stage: stage, target: target, interval: interval, wake: wake, resumed: resumed))
        }
        func receipt(relativeTo began: TimeInterval) -> [[String: Any]] {
            rows.enumerated().map { index, row in
                ["sequence": index + 1, "stage": row.stage, "target": row.target - began,
                 "interval": row.interval, "armed": row.wake.armed - began,
                 "fired": row.wake.fired - began, "resumed": row.resumed - began]
            }
        }
    }

    static func run(outputDirectory: URL) async throws -> [String: Any] {
        try require(CommandLine.arguments.contains("--music-test")
            && CommandLine.arguments.contains("--music-cache-test"), "synthetic-cache-only")
        let began = CACurrentMediaTime(), deadline = began + 3.0
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
        var samples: [Sample] = [], lifecycle: [[String: Any]] = []
        var timing: [[String: Any]] = []
        let wakes = WakeTrace()
        var completed = false
        func state() -> [String: Any] {
            ["time": CACurrentMediaTime() - began, "animationKeys": view.animationKeys,
             "animationStartCount": view.animationStartCount, "windowVisible": window.isVisible,
             "occlusionVisible": window.occlusionState.contains(.visible),
             "attached": view.window === window, "hidden": view.isHiddenOrHasHiddenAncestor]
        }
        func record(_ stage: String) {
            var row = state(); row["stage"] = stage; lifecycle.append(row)
        }
        func pause(until target: TimeInterval, stage: String) async throws {
            let requested = CACurrentMediaTime()
            try await nativePause(until: target, trace: wakes, stage: stage)
            timing.append(["stage": stage, "requested": requested - began,
                "target": target - began, "resumed": CACurrentMediaTime() - began])
        }
        func capture(_ stage: String) throws -> Capture {
            let started = CACurrentMediaTime()
            let image = try Self.capture(host, scale: window.backingScaleFactor)
            timing.append(["stage": stage, "started": started - began,
                "finished": CACurrentMediaTime() - began])
            return image
        }
        // A failed run retains the observations needed to distinguish aliasing,
        // absent pixels, interruption, restart, and a real scheduling deadline.
        defer {
            if !completed {
                let trace: [String: Any] = ["schema": 2, "deadlineSeconds": 3.0,
                    "observationDeadlineSeconds": 2.1, "periodSeconds": 1.6,
                    "samples": samples.map(\.receipt), "lifecycle": lifecycle, "finalState": state()]
                if let data = try? JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    print("MUSIC_INDICATOR_DIAGNOSTIC_JSON: \(json)")
                }
            }
            // Scheduling and export observations are diagnostic only. The
            // existing success receipt and all deadlines remain unchanged.
            if let data = try? JSONSerialization.data(withJSONObject: ["schema": 1, "timing": timing,
                "wakeSchema": 1, "wakeCapacity": WakeTrace.capacity, "droppedWakes": wakes.dropped,
                "wakes": wakes.receipt(relativeTo: began)], options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print("MUSIC_INDICATOR_TIMING_JSON: \(json)")
            }
        }
        view.configure(active: true, reduceMotion: false)
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await wait(deadline, label: "native-visible-start", trace: wakes) { running(view) }
        record("started")
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
        record("unchanged-inputs")
        let animations = view.barKeyframeAnimations
        try require(animations.count == 3 && animations.allSatisfy {
            let values = $0.values as? [NSNumber]
            return $0.keyPath == "transform.scale.y" && $0.duration == 1.6
                && $0.repeatCount.isInfinite && values?.count == 5 && values?.first == values?.last
                && $0.keyTimes == [0, 0.25, 0.5, 0.75, 1]
        }, "compositor-keyframes-and-loop-endpoints")

        func sample() throws -> Sample {
            let sampledAt = CACurrentMediaTime() - began
            var receipt = state(); receipt["time"] = sampledAt
            try require(running(view) && view.animationStartCount == starts && window.isVisible
                && window.occlusionState.contains(.visible) && view.window === window
                && !view.isHiddenOrHasHiddenAncestor, "uninterrupted-visible-cycle")
            let layers = view.layer?.sublayers?.compactMap { $0.presentation() } ?? []
            let scales = layers.map { Double($0.transform.m22) }
            let heights = layers.map { Double($0.frame.height) }
            try require(layers.count == 3 && scales.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 })
                && heights.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 14 }), "missing-native-presentation")
            let image = try capture("playing-capture")
            receipt["scales"] = scales; receipt["heights"] = heights; receipt["pngSHA256"] = image.pngSHA256
            return Sample(time: sampledAt, scales: scales, image: image, receipt: receipt)
        }
        try await pause(until: CACurrentMediaTime() + 0.14, stage: "initial-presentation")
        samples.append(try sample())
        let observationStart = began + samples[0].time
        let observationDeadline = observationStart + 2.1
        // Observe a complete period, even when an early pair already differs.
        // This is one bounded observation window, not retries of a failed test.
        while samples.last!.time - samples[0].time < 1.6 {
            // Use real observation timestamps rather than adding capture time
            // to every interval. Missed 80ms slots are skipped, never replayed
            // as a burst; actual samples still stay at least 80ms apart.
            let nextSlot = floor((CACurrentMediaTime() - observationStart) / 0.08) + 1
            let nextSample = max(observationStart + nextSlot * 0.08, began + samples.last!.time + 0.08)
            try await pause(until: nextSample, stage: "cycle-sample")
            try require(CACurrentMediaTime() <= observationDeadline && CACurrentMediaTime() <= deadline,
                "full-cycle-observation-deadline")
            samples.append(try sample())
        }
        let observationDuration = samples.last!.time - samples[0].time
        let ranges = (0..<3).map { index -> Double in
            let values = samples.map { $0.scales[index] }
            return values.max()! - values.min()!
        }
        try require(observationDuration >= 1.6 && observationDuration <= 2.1
            && ranges.allSatisfy { $0 > 0.01 }, "three-bars-move-over-full-cycle")
        let first = samples[0]
        guard let pairIndex = samples.indices.dropFirst().first(where: { index in
            let other = samples[index]
            return other.time - first.time >= 0.22
                && zip(first.scales, other.scales).allSatisfy({ abs($0.0 - $0.1) > 0.01 })
                && first.image.pixels != other.image.pixels
        }) else { throw Failure(label: "music-indicator-three-real-presentation-bars-and-pixels-advance") }
        let second = samples[pairIndex]
        let playingA = first.image, playingB = second.image
        let changedBytes = zip(playingA.pixels, playingB.pixels).filter { $0.0 != $0.1 }.count
        try require(changedBytes > 0, "selected-pair-pixels-change")
        record("observed-cycle")

        view.configure(active: false, reduceMotion: false)
        record("paused")
        try require(stopped(view), "pause-removes-animations")
        try await pause(until: CACurrentMediaTime() + 0.04, stage: "paused-presentation")
        let paused = try capture("paused-capture")
        try await pause(until: CACurrentMediaTime() + 0.05, stage: "paused-stability")
        try require(try capture("paused-stability-capture").pixels == paused.pixels,
            "paused-pixels-stable")
        try require(resting(view), "pause-restores-model-pose")

        view.configure(active: true, reduceMotion: false)
        try await wait(deadline, label: "resume-before-reduce-motion", trace: wakes) { running(view) }
        record("resume-before-reduce-motion")
        try await pause(until: CACurrentMediaTime() + 0.03, stage: "resumed-presentation")
        view.configure(active: true, reduceMotion: true)
        record("reduced-motion")
        try require(stopped(view), "reduce-motion-removes-animations")
        try await pause(until: CACurrentMediaTime() + 0.04, stage: "reduced-presentation")
        let reduced = try capture("reduced-capture")
        try await pause(until: CACurrentMediaTime() + 0.05, stage: "reduced-stability")
        try require(try capture("reduced-stability-capture").pixels == reduced.pixels
            && reduced.pixels == paused.pixels && resting(view), "reduce-motion-static-pose")

        view.configure(active: true, reduceMotion: false)
        try await wait(deadline, label: "resume-after-reduce-motion", trace: wakes) { running(view) }
        record("resume-after-reduce-motion")
        host.isHidden = true
        record("ancestor-hidden")
        try require(stopped(view), "hidden-ancestor-removes-animations")
        host.isHidden = false
        try await wait(deadline, label: "unhide-resumes", trace: wakes) { running(view) }
        record("ancestor-unhidden")
        window.orderOut(nil)
        try await wait(deadline, label: "order-out-removes-animations", trace: wakes) { !window.isVisible && stopped(view) }
        record("ordered-out")
        window.orderFrontRegardless()
        try await wait(deadline, label: "order-front-resumes", trace: wakes) { running(view) }
        record("ordered-front")
        view.removeFromSuperview()
        record("detached")
        try require(stopped(view), "detach-removes-animations")
        host.addSubview(view)
        try await wait(deadline, label: "reattach-resumes", trace: wakes) { running(view) }
        record("reattached")
        view.dismantle()
        record("dismantled")
        view.configure(active: true, reduceMotion: false)
        record("dismantled-reconfigure")
        try require(stopped(view), "dismantled-view-cannot-restart")
        try require(CACurrentMediaTime() <= deadline, "native-evidence-bounded")

        let exportStarted = CACurrentMediaTime()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let captures = [("playing-a", playingA), ("playing-b", playingB), ("paused", paused), ("reduced-motion", reduced)]
        for (name, image) in captures {
            try image.png.write(to: outputDirectory.appendingPathComponent("perimeter-indicator-\(name).png"), options: .atomic)
        }
        timing.append(["stage": "png-export", "started": exportStarted - began,
            "finished": CACurrentMediaTime() - began])
        let elapsed = CACurrentMediaTime() - began
        try require(elapsed <= 3.0, "native-capture-and-export-bounded")
        completed = true
        return ["schema": 2, "synthetic": true, "ownPresentationLayerPixels": true, "scanout": false,
            "elapsed": elapsed, "deadlineSeconds": 3.0, "periodSeconds": 1.6, "observationDeadlineSeconds": 2.1,
            "observationDuration": observationDuration, "observedRanges": ranges,
            "samples": samples.map(\.receipt), "lifecycle": lifecycle, "samplePairIndices": [0, pairIndex],
            "sampleTimes": [first.time, second.time], "scalesA": first.scales, "scalesB": second.scales,
            "changedBars": 3, "changedBytes": changedBytes,
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
    private static func wait(_ deadline: TimeInterval, label: String, trace: WakeTrace,
                             _ condition: () -> Bool) async throws {
        while !condition() {
            try require(CACurrentMediaTime() <= deadline, label)
            try await nativePause(until: CACurrentMediaTime() + 0.01, trace: trace, stage: label)
        }
    }
    /// Give each fixture wait an explicit native run-loop wake, not only a
    /// concurrency-task continuation. Timers are not real-time guarantees: the
    /// actual monotonic deadlines above still apply. This never advances CA
    /// time, forces a display, or changes the production animation behavior.
    private static func nativePause(until target: TimeInterval, trace: WakeTrace, stage: String) async throws {
        try Task.checkCancellation()
        while CACurrentMediaTime() < target {
            let remaining = target - CACurrentMediaTime()
            guard remaining > 0 else { break }
            let wake = await withCheckedContinuation { (continuation: CheckedContinuation<NativeWake, Never>) in
                let armed = CACurrentMediaTime()
                let timer = Timer(timeInterval: remaining, repeats: false) { _ in
                    continuation.resume(returning: NativeWake(armed: armed, fired: CACurrentMediaTime()))
                }
                timer.tolerance = 0
                RunLoop.main.add(timer, forMode: .common)
            }
            let resumed = CACurrentMediaTime()
            trace.record(stage: stage, target: target, interval: remaining, wake: wake, resumed: resumed)
            try Task.checkCancellation()
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
