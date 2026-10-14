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
    private let collapsedFrame: CGRect
    private let expandedFrame: CGRect
    public init(notch: NotchGeometry, screen: CGRect, backingScale: CGFloat = 1) {
        self.screen = screen
        self.notch = notch.notch
        self.backingScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        // Nominal 3pt extension; outward alignment adds <1 backing pixel per edge.
        // Align once relative to the actual camera bounds, including odd widths/origins.
        let scale = self.backingScale
        let left = floor((notch.notch.minX - 3) * scale) / scale
        let right = ceil((notch.notch.maxX + 3) * scale) / scale
        let bottom = floor((notch.notch.minY - 3) * scale) / scale
        collapsedFrame = CGRect(x: left, y: bottom, width: right - left, height: screen.maxY - bottom)
        collapsedSize = collapsedFrame.size
        let width = ceil(min(380, screen.width - 24) * scale / 2) * 2 / scale
        let height = ceil(min(notch.notch.height + 480, screen.height - 32) * scale) / scale
        let x = ((notch.notch.midX - width / 2) * scale).rounded() / scale
        expandedFrame = CGRect(x: x, y: screen.maxY - height, width: width, height: height)
        expandedSize = expandedFrame.size
    }
    public func frame(progress: Double) -> CGRect {
        let p = CGFloat(min(1, max(0, progress.isFinite ? progress : 0)))
        if p == 0 { return collapsedFrame }
        if p == 1 { return expandedFrame }
        // AppKit integralizes fractional NSWindow frames. Interpolate aligned
        // edges and normalize before native placement, sizing and hit-testing.
        let left = floor((collapsedFrame.minX + (expandedFrame.minX - collapsedFrame.minX) * p) * backingScale) / backingScale
        let right = ceil((collapsedFrame.maxX + (expandedFrame.maxX - collapsedFrame.maxX) * p) * backingScale) / backingScale
        let height = ceil((collapsedSize.height + (expandedSize.height - collapsedSize.height) * p) * backingScale) / backingScale
        return CGRect(x: left, y: screen.maxY - height, width: right - left, height: height)
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
