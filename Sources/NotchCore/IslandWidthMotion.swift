import Foundation

/// Unrounded presentation coordinates and their first time derivatives.
/// These travel with a render revision; NSWindow's rounded frame is never a motion input.
public struct IslandWidthSample: Equatable, Sendable {
    public var width: Double
    public var center: Double
    public var widthVelocity: Double
    public var centerVelocity: Double
    public init(width: Double, center: Double, widthVelocity: Double = 0, centerVelocity: Double = 0) {
        self.width = width; self.center = center
        self.widthVelocity = widthVelocity; self.centerVelocity = centerVelocity
    }
}

/// Applies only to this presentation progress. Canonical endpoint queries remain separate.
public struct IslandWidthPresentation: Equatable, Sendable {
    public let progress: Double
    public let sample: IslandWidthSample
    public init(progress: Double, sample: IslandWidthSample) { self.progress = progress; self.sample = sample }
}

/// A finite C1 bridge for an interrupted ordinary-hover width path. No timer or spring.
/// Width and center share one bounded braking segment and one interpolation parameter.
/// The feasible widths/centers/left/right edges form a convex region, so the whole
/// rectangle stays contained, including near-edge displays, without frame clamps.
public struct IslandWidthBridge: Equatable, Sendable {
    private let initial: IslandWidthSample
    private let stopped: IslandWidthSample
    private let brakingDuration: Double
    private let travelDuration: Double = 0.18
    public private(set) var elapsed: Double = 0
    public let target: IslandWidthSample
    public init(from: IslandWidthSample, to: IslandWidthSample,
                widthBounds: ClosedRange<Double>, centerBounds: ClosedRange<Double>,
                horizontalBounds: ClosedRange<Double>? = nil) {
        initial = from
        target = IslandWidthSample(width: to.width, center: to.center)
        var brake = (from.widthVelocity == 0 && from.centerVelocity == 0) ? 0.0 : 0.05
        func constrain(_ margin: Double, outwardVelocity: Double) {
            if outwardVelocity > 0 { brake = min(brake, 2 * max(0, margin) / outwardVelocity) }
        }
        constrain(widthBounds.upperBound - from.width, outwardVelocity: from.widthVelocity)
        constrain(from.width - widthBounds.lowerBound, outwardVelocity: -from.widthVelocity)
        constrain(centerBounds.upperBound - from.center, outwardVelocity: from.centerVelocity)
        constrain(from.center - centerBounds.lowerBound, outwardVelocity: -from.centerVelocity)
        if let bounds = horizontalBounds {
            constrain(from.center - from.width / 2 - bounds.lowerBound,
                      outwardVelocity: from.widthVelocity / 2 - from.centerVelocity)
            constrain(bounds.upperBound - from.center - from.width / 2,
                      outwardVelocity: from.centerVelocity + from.widthVelocity / 2)
        }
        brakingDuration = brake
        stopped = IslandWidthSample(width: from.width + from.widthVelocity * brake / 2,
            center: from.center + from.centerVelocity * brake / 2)
    }
    public var isSettled: Bool { elapsed >= brakingDuration + travelDuration }
    public var sample: IslandWidthSample {
        if elapsed == 0 { return initial }
        if elapsed < brakingDuration {
            let displacement = elapsed - elapsed * elapsed / (2 * brakingDuration)
            let velocityScale = 1 - elapsed / brakingDuration
            return IslandWidthSample(width: initial.width + initial.widthVelocity * displacement,
                center: initial.center + initial.centerVelocity * displacement,
                widthVelocity: initial.widthVelocity * velocityScale,
                centerVelocity: initial.centerVelocity * velocityScale)
        }
        if isSettled { return target }
        let t = min(1, max(0, (elapsed - brakingDuration) / travelDuration))
        let s = t * t * (3 - 2 * t), v = 6 * t * (1 - t) / travelDuration
        return IslandWidthSample(width: stopped.width + (target.width - stopped.width) * s,
            center: stopped.center + (target.center - stopped.center) * s,
            widthVelocity: (target.width - stopped.width) * v,
            centerVelocity: (target.center - stopped.center) * v)
    }
    public mutating func advance(elapsed delta: Double, reduceMotion: Bool = false) {
        if reduceMotion { elapsed = brakingDuration + travelDuration; return }
        guard delta.isFinite, delta > 0 else { return }
        elapsed = min(brakingDuration + travelDuration, elapsed + delta)
    }
}
