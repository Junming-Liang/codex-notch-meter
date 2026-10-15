#if os(macOS)
import Foundation
import NotchCore

/// One main-run-loop timer shared by the app's color consumers. No queued actor tasks.
@MainActor
final class SkinAnimator: NSObject {
    private var timer: Timer?
    private var clock = SkinPhaseClock()
    private var lastTick: TimeInterval = 0
    private let publish: (Double) -> Void
    private(set) var tickCount = 0
    private(set) var minimumTickInterval = TimeInterval.infinity
    var isRunning: Bool { timer != nil }
    var phase: Double { clock.phase }
    init(publish: @escaping (Double) -> Void) { self.publish = publish }
    func set(policy: SkinMotionPolicy, speed: SkinMotionSpeed) {
        let now = ProcessInfo.processInfo.systemUptime
        _ = clock.update(now: now, running: policy.isRunning)
        clock.speed = speed
        // Lifecycle notifications may arrive in bursts; only throttled ticks publish color.
        if !policy.isRunning { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        lastTick = now
        let timer = Timer(timeInterval: SkinMotionPolicy.frameInterval, target: self,
            selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        timer.tolerance = 0.005
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func tick(_ sender: Timer) {
        // A retired timer can never mutate a replacement, even during reentrant callbacks.
        guard sender === timer else { return }
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - lastTick
        guard elapsed >= SkinMotionPolicy.frameInterval else { return }
        minimumTickInterval = min(minimumTickInterval, elapsed)
        lastTick = now; tickCount += 1
        publish(clock.update(now: now, running: true))
    }
    func stop() {
        timer?.invalidate(); timer = nil
        _ = clock.update(now: ProcessInfo.processInfo.systemUptime, running: false)
    }
}

/// Safe native scheduling evidence. The scheduler is real; lifecycle flags are synthetic.
@MainActor
final class SkinAnimationHarness: NSObject {
    private var animator: SkinAnimator!
    private var timer: Timer?
    private var policy = SkinMotionPolicy(theme: .rainbow, hasVisibleOwnedSurface: true)
    private var index = 0
    private var resumingBetweenReasons = false
    private var started: TimeInterval = 0
    private var frozen: Double = 0
    private var valid = true
    private var publishCount = 0
    private var frozenPublicationCount = 0
    private var lastPublication: TimeInterval?
    private var minimumPublicationInterval = TimeInterval.infinity
    private let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    func start() {
        animator = SkinAnimator { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let previous = self.lastPublication { self.minimumPublicationInterval = min(self.minimumPublicationInterval, now - previous) }
            self.lastPublication = now; self.publishCount += 1
        }
        animator.set(policy: policy, speed: .normal)
        started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(check(_:)), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func check(_ sender: Timer) {
        guard sender === timer else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if resumingBetweenReasons {
            guard elapsed >= 0.2 else { return }
            let resumed = animator.isRunning && animator.phase > frozen
            valid = valid && resumed
            SmokeDiagnostics.mark("skin native between-pauses resume=\(index) phaseAdvanced=\(resumed)")
            resumingBetweenReasons = false; pauseNext(); return
        }
        if index == 8 {
            guard elapsed >= 0.25 else { return }
            let resumed = animator.isRunning && animator.phase > frozen
            valid = valid && resumed
            SmokeDiagnostics.mark("skin native resume phaseAdvanced=\(resumed)")
            animator.stop(); frozen = animator.phase; frozenPublicationCount = publishCount; index = 9; started = ProcessInfo.processInfo.systemUptime
            return
        }
        if index == 9 {
            guard elapsed >= 0.15 else { return }
            let retired = !animator.isRunning && animator.phase == frozen && publishCount == frozenPublicationCount
                && publishCount == animator.tickCount && minimumPublicationInterval >= SkinMotionPolicy.frameInterval - 0.0001
            valid = valid && retired
            SmokeDiagnostics.mark("skin native retired timer inert=\(retired)")
            stop(); completion(valid); return
        }
        if index == 0 {
            guard elapsed >= 0.35 else { return }
            if animator.tickCount < 2 && elapsed < 2 { return }
            valid = animator.phase > 0 && animator.tickCount >= 2
                && animator.minimumTickInterval >= SkinMotionPolicy.frameInterval
                && Double(animator.tickCount) <= ceil(elapsed * 15)
                && publishCount == animator.tickCount
                // Callback entry follows the throttle by a few microseconds.
                && minimumPublicationInterval >= SkinMotionPolicy.frameInterval - 0.0001
            SmokeDiagnostics.mark("skin native clock ticks=\(animator.tickCount) publications=\(publishCount) minInterval=\(animator.minimumTickInterval) minPublishInterval=\(minimumPublicationInterval) phase=\(animator.phase) valid=\(valid)")
        } else {
            guard elapsed >= 0.15 else { return }
            let stopped = !animator.isRunning && abs(animator.phase - frozen) < 0.000001
            valid = valid && stopped
            let reason = ["reduce-motion", "hidden", "sleep", "overlay-disabled", "motion-disabled", "low-power", "session-inactive"][index - 1]
            SmokeDiagnostics.mark("skin native pause reason=\(reason) frozen=\(stopped)")
        }
        if index == 7 {
            policy = SkinMotionPolicy(theme: .rainbow, hasVisibleOwnedSurface: true)
            animator.set(policy: policy, speed: .slow)
            frozen = animator.phase; index = 8; started = ProcessInfo.processInfo.systemUptime
            return
        }
        if index > 0 {
            policy = SkinMotionPolicy(theme: .rainbow, hasVisibleOwnedSurface: true)
            animator.set(policy: policy, speed: .normal)
            frozen = animator.phase; resumingBetweenReasons = true; started = ProcessInfo.processInfo.systemUptime
            return
        }
        pauseNext()
    }
    private func pauseNext() {
        policy = SkinMotionPolicy(theme: .rainbow, hasVisibleOwnedSurface: true)
        switch index {
        case 0: policy.reduceMotion = true
        case 1: policy.hasVisibleOwnedSurface = false
        case 2: policy.asleep = true
        case 3: policy.overlayEnabled = false
        case 4: policy.motionEnabled = false
        case 5: policy.lowPowerMode = true
        default: policy.sessionActive = false
        }
        let before = publishCount
        for _ in 0..<20 { animator.set(policy: policy, speed: .normal) }
        valid = valid && publishCount == before
        SmokeDiagnostics.mark("skin native policy burst publishedNoFrames=\(publishCount == before)")
        frozen = animator.phase; index += 1; started = ProcessInfo.processInfo.systemUptime
    }
    func stop() { timer?.invalidate(); timer = nil; animator?.stop() }
}
#endif
