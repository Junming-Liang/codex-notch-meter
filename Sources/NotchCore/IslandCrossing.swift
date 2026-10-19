import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pointer-only traversal of a fixed global corridor. Consecutive samples are
/// clipped to its edges: a real crossing must not depend on sampling a 28pt strip.
public struct IslandCrossing: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case right, left }
    private var origin: Direction?
    private var began: TimeInterval?
    private var last: CGPoint?
    private var lastTime: TimeInterval?
    private var crossedMiddle = false
    private var locked = false
    public init() {}
    public var isTracking: Bool { origin != nil && !locked }
    public var reservesPointer: Bool { origin != nil }
    public var isLocked: Bool { locked }
    public mutating func reset() { self = Self() }
    public mutating func update(point: CGPoint, now: TimeInterval, corridor: CGRect,
                                enabled: Bool, buttonDown: Bool = false) -> Direction? {
        guard enabled, !buttonDown, now.isFinite, point.x.isFinite, point.y.isFinite,
              corridor.origin.x.isFinite, corridor.origin.y.isFinite,
              corridor.size.width.isFinite, corridor.size.height.isFinite,
              corridor.size.width >= 48, corridor.size.height >= 4 else { reset(); return nil }
        let previous = last, previousTime = lastTime
        let inside = point.x >= corridor.minX && point.x <= corridor.maxX
            && point.y >= corridor.minY && point.y <= corridor.maxY
        if let time = previousTime, now <= time || now - time > 0.25 {
            reset(); locked = inside; last = point; lastTime = now; return nil
        }
        // Record outside samples too. They establish horizontal entry between
        // callbacks; a vertical/middle entry still cannot manufacture a gesture.
        defer { last = point; lastTime = now }
        if locked {
            if !inside { origin = nil; began = nil; crossedMiddle = false; locked = false }
            return nil
        }
        let zone = min(28, corridor.width * 0.18)
        if origin == nil {
            if let previous, let previousTime, previous.x != point.x {
                let right = previous.x < corridor.minX && point.x >= corridor.minX
                let left = previous.x > corridor.maxX && point.x <= corridor.maxX
                if right || left {
                    let edge = right ? corridor.minX : corridor.maxX
                    let fraction = (edge - previous.x) / (point.x - previous.x)
                    let y = previous.y + (point.y - previous.y) * fraction
                    if y >= corridor.minY && y <= corridor.maxY {
                        origin = right ? .right : .left
                        began = previousTime + Double(fraction) * (now - previousTime)
                    }
                }
            }
            if origin == nil {
                guard inside else { return nil }
                if let previous, previous.y < corridor.minY || previous.y > corridor.maxY {
                    locked = true; return nil
                }
                if point.x <= corridor.minX + zone { origin = .right }
                else if point.x >= corridor.maxX - zone { origin = .left }
                else { locked = true; return nil }
                began = now; return nil
            }
        }
        guard let direction = origin, let start = began, let previous else { reset(); return nil }
        guard now - start <= 1.2 else { origin = nil; locked = inside; return nil }
        let signedDelta = direction == .right ? point.x - previous.x : previous.x - point.x
        guard signedDelta >= -4 else { origin = nil; locked = inside; return nil }
        // Clip a sampled overshoot to the horizontal exit edge and verify that
        // it actually left through that edge, rather than above/below the band.
        var endpoint = point
        if direction == .right && point.x > corridor.maxX || direction == .left && point.x < corridor.minX {
            let edge = direction == .right ? corridor.maxX : corridor.minX
            let fraction = (edge - previous.x) / (point.x - previous.x)
            endpoint = CGPoint(x: edge, y: previous.y + (point.y - previous.y) * fraction)
        }
        guard endpoint.y >= corridor.minY && endpoint.y <= corridor.maxY else {
            origin = nil; began = nil; crossedMiddle = false; return nil
        }
        if direction == .right, previous.x <= corridor.midX, endpoint.x >= corridor.midX { crossedMiddle = true }
        if direction == .left, previous.x >= corridor.midX, endpoint.x <= corridor.midX { crossedMiddle = true }
        let reached = direction == .right ? endpoint.x >= corridor.maxX - zone : endpoint.x <= corridor.minX + zone
        guard crossedMiddle, reached else { return nil }
        // Distance and a continuous, time-bounded traversal prove intent; a
        // minimum duration used to reject fast legitimate mouse movements.
        if inside { locked = true }
        else { origin = nil; began = nil; crossedMiddle = false }
        return direction
    }
}

/// A gesture owns the resulting presentation until the pointer leaves a stable
/// envelope. An appearing or shrinking shell cannot turn the same motion into hover.
public struct IslandGestureHoverGate: Equatable, Sendable {
    public private(set) var isSuppressing = false
    public init() {}
    public mutating func claim() { isSuppressing = true }
    public mutating func reset() { isSuppressing = false }
    public mutating func suppresses(insideStableEnvelope: Bool) -> Bool {
        if !insideStableEnvelope { isSuppressing = false }
        return isSuppressing
    }
}
