#if os(macOS)
import AppKit
import QuartzCore
import NotchCore

/// Inject a non-delivering driver, not fake paint/animation success. The green
/// path drives the real panel via the production recovery wrapper and timer.
/// This is induced fault evidence, not proof of a user's physical display fault.
@MainActor
enum FrameRecoveryChecks {
    private struct Failure: Error { let label: String }
    private final class PanelHolder { weak var panel: IslandPanelController? }
    private final class SilentFrames: IslandFrameSource {
        let callback: (TimeInterval) -> Void
        private(set) var isRunning = true
        var kind: String { "synthetic-silent" }
        init(_ callback: @escaping (TimeInterval) -> Void) { self.callback = callback }
        func stop() { isRunning = false }
        func verifyRetiredCallbackIsInert() -> Bool { stop(); return !isRunning }
        func lateCallback() { callback(CACurrentMediaTime()) }
        func emit(_ time: TimeInterval) { callback(time) }
    }
    private static func require(_ condition: Bool, _ label: String) throws {
        if !condition { throw Failure(label: label) }
    }
    private static func wait(_ condition: @escaping () -> Bool, seconds: Double = 3) async throws {
        let until = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < until && !Task.isCancelled {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(label: "frame-recovery-condition-timeout")
    }
    private static func notice() throws -> RefreshNotice {
        let firstTime = Date().addingTimeInterval(-2), now = Date(), reset = now.addingTimeInterval(3600)
        func sample(_ used: Int, _ time: Date) throws -> QuotaSnapshot {
            let json = "{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":\(reset.timeIntervalSince1970)}}}"
            return try QuotaParser.parse(Data(json.utf8), fetchedAt: time)
        }
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(try sample(20, firstTime), at: firstTime)
        let next = try sample(21, now), result = tracker.record(next, at: now)
        guard let notice = RefreshNotice.make(result: result, snapshot: next, preferredBucketID: nil,
            preferredWindowID: nil, duration: .short, receivedAt: now) else { throw Failure(label: "notice-fixture") }
        return notice
    }
    static func run() async throws -> [String: Any] {
        guard CommandLine.arguments.contains("--music-cache-test"), let screen = NSScreen.main else {
            throw Failure(label: "explicit-native-test-only")
        }
        let frame = screen.frame
        guard let notch = NotchGeometry.calculate(screen: frame, topInset: 32,
            auxiliaryLeft: CGRect(x: frame.minX, y: frame.maxY - 32,
                width: frame.midX - 100 - frame.minX, height: 32),
            auxiliaryRight: CGRect(x: frame.midX + 100, y: frame.maxY - 32,
                width: frame.maxX - frame.midX - 100, height: 32)) else {
            throw Failure(label: "frame-recovery-geometry")
        }
        let geometry = IslandGeometry(notch: notch,
            screen: frame, backingScale: screen.backingScaleFactor, contentHeight: 260)
        let model = MeterModel(demo: true)
        defer { model.stop() }
        let change = try notice()
        // Red control: the pre-fix production choice has no callback fallback.
        let red = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: false, testFrameFactory: { SilentFrames($0) },
            hovered: {}, refresh: {}, settings: {}, quit: {})
        defer { red.stop() }
        try await wait { red.permitsMotionRecovery }
        try require(red.showRefreshNotice(change), "red-accepted")
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(red.smokeProgress == 0 && red.smokeNoticeArmedAt == nil && red.smokeMotionRunning,
                    "red-silent-driver-reproduces-no-popup")
        red.stop()

        var driver: RecoveringIslandFrames?
        var primary: SilentFrames?
        let holder = PanelHolder()
        var green: IslandPanelController!
        green = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: false, testFrameFactory: { callback in
                let value = RecoveringIslandFrames(makePrimary: { handler in
                    let silent = SilentFrames(handler); primary = silent; return silent
                }, presentationAllowed: { [weak holder] in holder?.panel?.permitsMotionRecovery == true }, callback: callback)
                driver = value; return value
            }, hovered: {}, refresh: {}, settings: {}, quit: {})
        holder.panel = green
        defer { green.stop() }
        try await wait { green.permitsMotionRecovery }
        let greenStarted = CACurrentMediaTime()
        try require(green.showRefreshNotice(change), "green-accepted")
        try await wait { green.smokeNoticeArmedAt != nil && green.smokeNoticePaintReadyAt != nil && !green.smokeMotionRunning }
        try require(driver?.fallbackCount == 1 && primary?.isRunning == false && driver?.hasWatchdog == false,
                    "green-one-fallback-and-retired-timers")
        let fallbackElapsed = (driver?.fallbackAt ?? -.infinity) - greenStarted
        try require(fallbackElapsed >= 0.3 && fallbackElapsed < 2, "bounded-fallback-time")
        let progress = green.smokeProgress
        primary?.lateCallback()
        try require(green.smokeProgress == progress, "old-primary-callback-inert")
        green.collapse()
        try await wait { green.smokeProgress == 0 && !green.smokeMotionRunning }
        try require(green.beginSmokeExpansion(), "hover-accepted")
        try await wait { green.smokeProgress == 1 && !green.smokeMotionRunning && green.isInteracting }
        green.stop()
        try require(driver?.verifyRetiredCallbackIsInert() == true, "stop-no-watchdog-or-callback")

        // A genuinely hidden/offscreen surface must not start the timer fallback.
        var hiddenDeliveries = 0, hiddenAllowed = false
        let hidden = RecoveringIslandFrames(makePrimary: { SilentFrames($0) },
            presentationAllowed: { hiddenAllowed }, callback: { _ in hiddenDeliveries += 1 })
        defer { hidden.stop() }
        try await Task.sleep(nanoseconds: 450_000_000)
        try require(hidden.fallbackCount == 0 && !hidden.hasWatchdog && hiddenDeliveries == 0,
                    "hidden-no-fallback-or-heartbeat")
        hiddenAllowed = true; hidden.presentationAvailabilityChanged()
        try await wait { hiddenDeliveries > 0 }
        try require(hidden.fallbackCount == 1, "visibility-recovery")
        hiddenAllowed = false
        try await Task.sleep(nanoseconds: 100_000_000)
        let suspendedDeliveries = hiddenDeliveries
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(hiddenDeliveries == suspendedDeliveries && !hidden.isRunning && !hidden.hasWatchdog,
                    "fallback-suspends-when-hidden")
        hiddenAllowed = true; hidden.presentationAvailabilityChanged()
        try await wait { hiddenDeliveries > suspendedDeliveries }
        hidden.stop()

        var repeatedPrimary: SilentFrames?
        var repeatedDeliveries: [TimeInterval] = []
        let repeated = RecoveringIslandFrames(makePrimary: { handler in
            let value = SilentFrames(handler); repeatedPrimary = value; return value
        }, presentationAllowed: { true }, callback: { repeatedDeliveries.append($0) })
        defer { repeated.stop() }
        let repeatedTime = CACurrentMediaTime()
        for _ in 0..<7 {
            repeatedPrimary?.emit(repeatedTime)
            repeatedPrimary?.emit(.nan)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        try await wait { repeated.fallbackCount == 1 && repeatedDeliveries.count > 1 }
        try require(zip(repeatedDeliveries, repeatedDeliveries.dropFirst()).allSatisfy { $0.1 > $0.0 },
                    "nonmonotonic-timestamps-do-not-renew-lease")
        repeated.stop()

        var reducedFactoryCalls = 0
        let reduced = IslandPanelController(model: model, geometry: geometry, startPolling: false,
            reducedMotionOverride: true, testFrameFactory: { callback in
                reducedFactoryCalls += 1; return SilentFrames(callback)
            }, hovered: {}, refresh: {}, settings: {}, quit: {})
        defer { reduced.stop() }
        try require(reduced.showRefreshNotice(change), "reduced-accepted")
        try await wait { reduced.smokeNoticeArmedAt != nil }
        try require(reducedFactoryCalls == 0 && !reduced.smokeMotionRunning, "reduced-motion-no-driver")
        return ["syntheticFault": true, "fieldRootProven": false, "redNoProgress": true,
            "greenNaturalPaint": true, "productionVisibilityGuard": true, "invalidTimestampsRejected": true, "hoverRecovered": true, "singleFallback": true,
            "retiredCallbacksInert": true, "hiddenNoFallback": true, "reducedMotionPreserved": true,
            "stoppedNoWatchdog": true, "visibilityResume": true, "fallbackElapsed": fallbackElapsed, "scanout": false]
    }
}
#endif
