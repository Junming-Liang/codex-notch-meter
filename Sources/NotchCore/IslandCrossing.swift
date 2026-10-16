import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A pointer-only crossing of a fixed global corridor. No button, event tap,
/// window geometry or hover dwell can manufacture a direction change.
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
              corridor.size.width >= 48, corridor.size.height >= 4,
              point.x >= corridor.minX, point.x <= corridor.maxX,
              point.y >= corridor.minY, point.y <= corridor.maxY else { reset(); return nil }
        if locked { return nil }
        if let time = lastTime, now <= time { reset(); locked = true; return nil }
        if let time = lastTime, now - time > 0.25 { reset(); locked = true; return nil }
        let zone = min(28, corridor.width * 0.18)
        if origin == nil {
            if point.x <= corridor.minX + zone { origin = .right }
            else if point.x >= corridor.maxX - zone { origin = .left }
            else { locked = true; return nil } // Entering the middle is ordinary hover.
            began = now; last = point; lastTime = now; return nil
        }
        guard let direction = origin, let start = began, let previous = last else { reset(); return nil }
        guard now - start <= 1.2 else { reset(); locked = true; return nil }
        let signedDelta = direction == .right ? point.x - previous.x : previous.x - point.x
        guard signedDelta >= -4 else { reset(); locked = true; return nil }
        last = point; lastTime = now
        if direction == .right, previous.x <= corridor.midX, point.x >= corridor.midX { crossedMiddle = true }
        if direction == .left, previous.x >= corridor.midX, point.x <= corridor.midX { crossedMiddle = true }
        let reached = direction == .right ? point.x >= corridor.maxX - zone : point.x <= corridor.minX + zone
        guard crossedMiddle, reached, now - start >= 0.06 else { return nil }
        locked = true
        return direction
    }
}
