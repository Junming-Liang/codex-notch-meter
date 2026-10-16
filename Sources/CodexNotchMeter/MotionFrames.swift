#if os(macOS)
import AppKit
import QuartzCore

/// Geometry callbacks run directly on the main run loop; no queued task can pile up.
@MainActor
protocol IslandFrameSource: AnyObject {
    var kind: String { get }
    var isRunning: Bool { get }
    func stop()
    func verifyRetiredCallbackIsInert() -> Bool
}

@MainActor
final class TimerIslandFrames: NSObject, IslandFrameSource {
    private var timer: Timer?
    private let callback: (TimeInterval) -> Void
    private var deliveries = 0
    var kind: String { "timer-60hz" }
    var isRunning: Bool { timer != nil }
    init(callback: @escaping (TimeInterval) -> Void) {
        self.callback = callback
        super.init()
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func tick(_ sender: Timer) {
        guard sender === timer else { return }
        deliveries += 1; callback(CACurrentMediaTime())
    }
    func stop() { timer?.invalidate(); timer = nil }
    func verifyRetiredCallbackIsInert() -> Bool {
        let old = timer, count = deliveries
        stop()
        if let old { tick(old) }
        return !isRunning && deliveries == count
    }
}

/// Short-transition fallback for macOS 13. Dispatch sources coalesce pending events;
/// this never queues one block per missed frame or holds a process power assertion.
@MainActor
final class DispatchIslandFrames: IslandFrameSource {
    private var source: DispatchSourceTimer?
    private let callback: (TimeInterval) -> Void
    private var generation = 1
    private var deliveries = 0
    var kind: String { "dispatch-60hz" }
    var isRunning: Bool { source != nil }
    init(callback: @escaping (TimeInterval) -> Void) {
        self.callback = callback
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        self.source = source
        let generation = self.generation
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick(generation: generation)
            }
        }
        source.schedule(deadline: .now() + .nanoseconds(16_666_667),
            repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
        source.resume()
    }
    private func tick(generation: Int) {
        guard generation == self.generation, source != nil else { return }
        deliveries += 1; callback(CACurrentMediaTime())
    }
    func stop() { generation += 1; source?.cancel(); source = nil }
    func verifyRetiredCallbackIsInert() -> Bool {
        let retiredGeneration = generation, count = deliveries
        stop(); tick(generation: retiredGeneration)
        return !isRunning && deliveries == count
    }
}

/// Availability is isolated so the app still loads and runs on macOS13.
@available(macOS 14.0, *)
@MainActor
final class DisplayIslandFrames: NSObject, IslandFrameSource {
    private var link: CADisplayLink?
    private let callback: (TimeInterval) -> Void
    private var deliveries = 0
    var kind: String { "view-display-link" }
    var isRunning: Bool { link != nil }
    init(view: NSView, callback: @escaping (TimeInterval) -> Void) {
        self.callback = callback
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        // High refresh is requested only for the brief geometry transition, never idle color.
        let maximum: Float = ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 120
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ sender: CADisplayLink) {
        guard sender === link else { return }
        deliveries += 1; callback(sender.targetTimestamp)
    }
    func stop() { link?.invalidate(); link = nil }
    func verifyRetiredCallbackIsInert() -> Bool {
        let old = link, count = deliveries
        stop()
        if let old { tick(old) }
        return !isRunning && deliveries == count
    }
}

/// The baseline is used only by the explicit demo motion harness, never a user preference.
enum IslandMotionProfile: String {
    case adaptive, timerFallback, synchronousBaseline
    var prewarmsDetails: Bool { self != .synchronousBaseline }
    var forcesLayout: Bool { self == .synchronousBaseline }
}

struct IslandMotionSample {
    let observed: TimeInterval
    let scheduled: TimeInterval
    let generation: Int
    let applyDuration: TimeInterval
    let progress: Double
    let velocity: Double
    let expanded: Bool
    let frame: CGRect
    let contentBounds: CGRect
    let viewport: CGSize
    let visible: Bool
    let nonKey: Bool
    let source: String
}

struct IslandMotionProbe {
    let observed: TimeInterval
    let frame: CGRect
    let contentBounds: CGRect
    let layerPresentation: CGRect?
    let viewport: CGSize
    let renderedProgress: Double
    let renderedAt: TimeInterval
    let requestedProgress: Double
    let visible: Bool
    let nonKey: Bool
    let running: Bool
}

/// One progress drives every visual stage; reversing cannot restart an independent fade.
enum IslandReveal {
    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value.isFinite ? value : 0))
        return t * t * (3 - 2 * t)
    }
    static func rail(_ progress: Double) -> Double { 1 - smooth(progress) }
    static func details(_ progress: Double) -> Double { smooth((progress - 0.32) / 0.58) }
}
#endif
