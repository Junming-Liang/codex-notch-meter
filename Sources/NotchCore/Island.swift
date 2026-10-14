import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pointer hysteresis is independent of animation, accounts, and the current display.
public struct IslandHoverState: Equatable, Sendable {
    public private(set) var isExpanded = false
    private var enteredAt: TimeInterval?
    private var leftAt: TimeInterval?
    public init() {}
    public mutating func update(inside: Bool, now: TimeInterval) {
        if inside {
            leftAt = nil
            if enteredAt == nil { enteredAt = now }
            if !isExpanded, now - (enteredAt ?? now) >= 0.12 { isExpanded = true }
        } else {
            enteredAt = nil
            if leftAt == nil { leftAt = now }
            if isExpanded, now - (leftAt ?? now) >= 0.22 { isExpanded = false }
        }
    }
    public mutating func reset() { self = IslandHoverState() }
}

/// A bounded, interruption-safe spring. The same progress drives window and silhouette.
public struct IslandMotion: Equatable, Sendable {
    public private(set) var progress: Double = 0
    public private(set) var velocity: Double = 0
    public init() {}
    public mutating func advance(expanded: Bool, elapsed: TimeInterval, reduceMotion: Bool) {
        let target: Double = expanded ? 1 : 0
        if reduceMotion { progress = target; velocity = 0; return }
        guard elapsed.isFinite, elapsed > 0 else { return }
        let duration = min(elapsed, 0.1)
        let steps = max(1, Int(ceil(duration * 120)))
        let dt = duration / Double(steps)
        for _ in 0..<steps {
            let acceleration = 260 * (target - progress) - 30 * velocity
            velocity += acceleration * dt
            progress += velocity * dt
            if progress < 0 { progress = 0; velocity = max(0, velocity) }
            if progress > 1 { progress = 1; velocity = min(0, velocity) }
        }
        if abs(target - progress) < 0.001 && abs(velocity) < 0.015 { progress = target; velocity = 0 }
    }
    public var isSettled: Bool { velocity == 0 && (progress == 0 || progress == 1) }
}

public struct IslandGeometry: Equatable, Sendable {
    public let screen: CGRect
    public let notch: CGRect
    public let collapsedSize: CGSize
    public let expandedSize: CGSize
    public let backingScale: CGFloat
    public init(notch: NotchGeometry, screen: CGRect, backingScale: CGFloat = 1) {
        self.screen = screen
        self.notch = notch.notch
        self.backingScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        collapsedSize = CGSize(width: notch.notch.width + 12, height: notch.notch.height + 7)
        expandedSize = CGSize(width: min(380, screen.width - 24), height: min(notch.notch.height + 480, screen.height - 32))
    }
    public func frame(progress: Double) -> CGRect {
        let p = CGFloat(min(1, max(0, progress.isFinite ? progress : 0)))
        let rawWidth = collapsedSize.width + (expandedSize.width - collapsedSize.width) * p
        let rawHeight = collapsedSize.height + (expandedSize.height - collapsedSize.height) * p
        // AppKit integralizes fractional NSWindow frames. Normalize BEFORE sizing
        // and hit-testing, so legitimate rounding cannot trip the placement guard.
        // Even pixel widths preserve centering while both horizontal edges align.
        let width = ceil(rawWidth * backingScale / 2) * 2 / backingScale
        let height = ceil(rawHeight * backingScale) / backingScale
        let x = ((notch.midX - width / 2) * backingScale).rounded() / backingScale
        return CGRect(x: x, y: screen.maxY - height, width: width, height: height)
    }
    public func hoverContains(_ point: CGPoint, progress: Double) -> Bool {
        // Never use visibleFrame: the island is attached to the physical top edge.
        frame(progress: progress).contains(point)
    }
    public func interactiveContains(_ point: CGPoint) -> Bool {
        let frame = frame(progress: 1)
        // Only the fully revealed content accepts clicks, not corners or hardware cutout.
        return CGRect(x: frame.minX + 16, y: frame.minY + 16,
            width: frame.width - 32, height: frame.height - notch.height - 28).contains(point)
    }
}
