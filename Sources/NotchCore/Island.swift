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

/// A user correction in points, independent of a display's backing scale.
public enum HorizontalCalibration {
    public static func sanitized(_ value: Double = 0) -> Double {
        guard value.isFinite else { return 0 }
        return (min(8, max(-8, value)) * 2).rounded() / 2
    }
}

public struct IslandGeometry: Equatable, Sendable {
    public let screen: CGRect
    /// Unmodified system-reported camera exclusion bounds from the auxiliary regions.
    public let notch: CGRect
    public let horizontalAdjustment: Double
    public let calibratedNotch: CGRect
    /// Exact collapsed contour in global coordinates: 3pt on the sides/bottom.
    public let contourFrame: CGRect
    public let collapsedSize: CGSize
    public let expandedSize: CGSize
    public let backingScale: CGFloat
    private let expandedContourFrame: CGRect
    public init(notch: NotchGeometry, screen: CGRect, backingScale: CGFloat = 1, horizontalAdjustment: Double = 0) {
        let hardware = notch.notch
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let width = min(380, screen.width - 24)
        let height = min(hardware.height + 480, screen.height - 32)
        let screenLeft = ceil(screen.minX * scale) / scale
        let screenRight = floor(screen.maxX * scale) / scale
        let expandedLeft = ceil((screen.minX + 12) * scale) / scale
        let expandedRight = floor((screen.maxX - 12) * scale) / scale
        var lower = max(-8, screenLeft - (hardware.minX - 3))
        var upper = min(8, screenRight - (hardware.maxX + 3))
        let centeredCardFits = hardware.midX - width / 2 >= expandedLeft
            && hardware.midX + width / 2 <= expandedRight
        if centeredCardFits {
            lower = max(lower, expandedLeft + width / 2 - hardware.midX)
            upper = min(upper, expandedRight - width / 2 - hardware.midX)
        }
        // Valid hardware has room for its 3pt contour. Restrict corrections to
        // half-point steps that keep both that contour and the centered card in bounds.
        // Zero stays zero; unsupported hardware must never acquire a hidden correction.
        let requested = HorizontalCalibration.sanitized(horizontalAdjustment)
        let adjustment: Double
        if lower <= 0 && upper >= 0 {
            adjustment = min(Double(floor(upper * 2) / 2), max(Double(ceil(lower * 2) / 2), requested))
        } else {
            adjustment = requested
        }
        self.screen = screen
        self.notch = hardware
        self.horizontalAdjustment = adjustment
        calibratedNotch = hardware.offsetBy(dx: adjustment, dy: 0)
        self.backingScale = scale
        contourFrame = CGRect(x: calibratedNotch.minX - 3, y: calibratedNotch.minY - 3,
            width: calibratedNotch.width + 6, height: calibratedNotch.height + 3)
        // Exception for a system-reported near-edge notch: retain a usable full
        // card and contain it in the screen margins. Only the expanded card moves;
        // the raw notch and exact collapsed contour are never recentered.
        let expandedX = min(max(calibratedNotch.midX - width / 2, expandedLeft), expandedRight - width)
        expandedContourFrame = CGRect(x: expandedX,
            y: screen.maxY - height, width: width, height: height)
        collapsedSize = Self.nativeFrame(containing: contourFrame, screen: screen, scale: scale).size
        expandedSize = Self.nativeFrame(containing: expandedContourFrame, screen: screen, scale: scale).size
    }
    public func frame(progress: Double) -> CGRect {
        Self.nativeFrame(containing: drawingFrame(progress: progress), screen: screen, scale: backingScale)
    }
    /// Exact drawing rectangle in top-down coordinates inside the normalized window.
    /// Its origin must be honored; centering it in the window reintroduces grid bias.
    public func contourRect(progress: Double) -> CGRect {
        localRect(drawingFrame(progress: progress), progress: progress)
    }
    /// The fixed collapsed rail, translated into the current top-down window.
    public func railRect(progress: Double) -> CGRect {
        localRect(contourFrame, progress: progress)
    }
    private func localRect(_ contour: CGRect, progress: Double) -> CGRect {
        let native = frame(progress: progress)
        return CGRect(x: contour.minX - native.minX, y: native.maxY - contour.maxY,
            width: contour.width, height: contour.height)
    }
    private func drawingFrame(progress: Double) -> CGRect {
        let p = CGFloat(min(1, max(0, progress.isFinite ? progress : 0)))
        if p == 0 { return contourFrame }
        if p == 1 { return expandedContourFrame }
        let width = contourFrame.width + (expandedContourFrame.width - contourFrame.width) * p
        let height = contourFrame.height + (expandedContourFrame.height - contourFrame.height) * p
        let center = calibratedNotch.midX + (expandedContourFrame.midX - calibratedNotch.midX) * p
        return CGRect(x: center - width / 2,
            y: screen.maxY - height, width: width, height: height)
    }
    private static func nativeFrame(containing contour: CGRect, screen: CGRect, scale: CGFloat) -> CGRect {
        // Only the transparent native envelope is aligned. The visible contour
        // retains its exact midpoint even for odd widths and fractional origins.
        let left = floor(contour.minX * scale) / scale
        let right = ceil(contour.maxX * scale) / scale
        let bottom = floor(contour.minY * scale) / scale
        return CGRect(x: left, y: bottom, width: right - left, height: screen.maxY - bottom)
    }
    public func hoverContains(_ point: CGPoint, progress: Double) -> Bool {
        // Never use visibleFrame: the island is attached to the physical top edge.
        drawingFrame(progress: progress).contains(point)
    }
    public func interactiveContains(_ point: CGPoint) -> Bool {
        let frame = drawingFrame(progress: 1)
        // Only the fully revealed content accepts clicks, not corners or hardware cutout.
        return CGRect(x: frame.minX + 16, y: frame.minY + 16,
            width: frame.width - 32, height: frame.height - notch.height - 28).contains(point)
    }
}
