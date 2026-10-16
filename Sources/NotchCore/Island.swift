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
    public mutating func update(inside: Bool, now: TimeInterval, resumeExpanded: Bool = false) {
        if inside {
            leftAt = nil
            if enteredAt == nil { enteredAt = now }
            // The caller may resume a still-visible closing island immediately.
            // Initial entry keeps its dwell, and an outside hint never opens it.
            if !isExpanded, resumeExpanded || now - (enteredAt ?? now) >= 0.12 { isExpanded = true }
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
        advance(target: expanded ? 1 : 0, elapsed: elapsed, reduceMotion: reduceMotion)
    }
    public mutating func advance(target requested: Double, elapsed: TimeInterval, reduceMotion: Bool) {
        guard requested.isFinite else { return }
        let target = min(1, max(0, requested))
        if reduceMotion { progress = target; velocity = 0; return }
        guard elapsed.isFinite, elapsed > 0 else { return }
        // Exact critically damped solution, in normalized progress per second.
        // 16 rad/s reaches 99% in about0.415s, informed by DynamicNotchKit's
        // 0.4s reference rhythm while retaining this bounded, non-overshooting solver.
        // Preserve both state values when the target changes; never restart an easing.
        let frequency = 16.0
        let displacement = progress - target
        let coefficient = velocity + frequency * displacement
        let decay = exp(-frequency * elapsed)
        // Consume a whole finite gap. Check underflow before elapsed products, so
        // even greatestFiniteMagnitude cannot produce infinity * zero or NaN.
        if decay == 0 { progress = target; velocity = 0; return }
        let nextProgress = target + (displacement + coefficient * elapsed) * decay
        let nextVelocity = (velocity - frequency * coefficient * elapsed) * decay
        // Critical damping has a nonnegative response to a bounded target, so
        // reachable states stay in 0...1 even during reversals. Clamp roundoff only.
        progress = min(1, max(0, nextProgress))
        velocity = nextVelocity
        if progress == 0 { velocity = max(0, velocity) }
        if progress == 1 { velocity = min(0, velocity) }
        // Exact endpoints stop the scheduler. The final snap remains bounded by
        // 0.001 normalized position and 0.015 normalized velocity, as before.
        if abs(target - progress) < 0.001 && abs(velocity) < 0.015 { progress = target; velocity = 0 }
    }
    public func isSettled(at target: Double) -> Bool { velocity == 0 && progress == target }
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
    public let shapeCalibration: ContourCalibration
    public let calibratedNotch: CGRect
    /// Exact collapsed contour in global coordinates: 3pt on the sides/bottom.
    public let contourFrame: CGRect
    public let collapsedSize: CGSize
    public let expandedSize: CGSize
    public let contentHeight: CGFloat
    public let backingScale: CGFloat
    private let expandedContourFrame: CGRect
    public init(notch: NotchGeometry, screen: CGRect, backingScale: CGFloat = 1, horizontalAdjustment: Double = 0, shapeCalibration: ContourCalibration = ContourCalibration(), contentHeight: CGFloat = 180) {
        let hardware = notch.notch
        // Keep the OS camera exclusion unchanged. Only the user-visible contour is corrected.
        let topFlare = min(0.5, max(0, 4 * min(2, max(0.5, hardware.height / 32)) - 3))
        let allowance = 3 + topFlare
        let maxWidth = max(18, 2 * min(hardware.midX - screen.minX - allowance, screen.maxX - hardware.midX - allowance))
        let correctedWidth = min(maxWidth, max(18, hardware.width + shapeCalibration.width))
        let correctedDepth = min(screen.height - 35, max(9, hardware.height + shapeCalibration.depth))
        let corrected = CGRect(x: hardware.midX - correctedWidth / 2,
            y: hardware.maxY - correctedDepth, width: correctedWidth, height: correctedDepth)
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let width = min(max(340, hardware.width + 40), screen.width - 24)
        let content = min(340, max(132, contentHeight.isFinite ? contentHeight : 180))
        let height = min(hardware.height + 8 + content, screen.height - 32)
        self.contentHeight = height - hardware.height - 8
        let screenLeft = ceil(screen.minX * scale) / scale
        let screenRight = floor(screen.maxX * scale) / scale
        let expandedLeft = ceil((screen.minX + 12) * scale) / scale
        let expandedRight = floor((screen.maxX - 12) * scale) / scale
        var lower = max(-8, screenLeft - (corrected.minX - allowance))
        var upper = min(8, screenRight - (corrected.maxX + allowance))
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
        self.shapeCalibration = shapeCalibration
        calibratedNotch = corrected.offsetBy(dx: adjustment, dy: 0)
        self.backingScale = scale
        contourFrame = CGRect(x: calibratedNotch.minX - 3, y: calibratedNotch.minY - 3,
            width: calibratedNotch.width + 6, height: calibratedNotch.height + 3)
        // Exception for a system-reported near-edge notch: retain a usable full
        // card and contain it in the screen margins. Only the expanded card moves;
        // the raw notch and exact collapsed contour are never recentered.
        let expandedX = min(max(calibratedNotch.midX - width / 2, expandedLeft), expandedRight - width)
        expandedContourFrame = CGRect(x: expandedX,
            y: screen.maxY - height, width: width, height: height)
        collapsedSize = Self.nativeFrame(containing: IslandContour(rect: contourFrame, cornerAdjustment: shapeCalibration.corner, referenceDepth: hardware.height).bounds, screen: screen, scale: scale).size
        expandedSize = Self.nativeFrame(containing: expandedContourFrame, screen: screen, scale: scale).size
    }
    public var updateProgress: Double {
        let updateHeight = min(expandedContourFrame.height - 20, notch.height + 78)
        return Double(max(0.15, min(0.8, (updateHeight - contourFrame.height) / (expandedContourFrame.height - contourFrame.height))))
    }
    public func hasSameAnchor(as other: IslandGeometry) -> Bool {
        screen == other.screen && notch == other.notch && horizontalAdjustment == other.horizontalAdjustment
            && shapeCalibration == other.shapeCalibration && backingScale == other.backingScale
    }
    public func frame(progress: Double) -> CGRect {
        Self.nativeFrame(containing: IslandContour(rect: drawingFrame(progress: progress), progress: progress, cornerAdjustment: shapeCalibration.corner, referenceDepth: notch.height).bounds, screen: screen, scale: backingScale)
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
        // Reach the wrapped pill width smoothly before continuing down to details.
        let widthProgress = min(1, p / CGFloat(updateProgress))
        let widthEase = widthProgress * widthProgress * (3 - 2 * widthProgress)
        let width = contourFrame.width + (expandedContourFrame.width - contourFrame.width) * widthEase
        let height = contourFrame.height + (expandedContourFrame.height - contourFrame.height) * p
        let center = calibratedNotch.midX + (expandedContourFrame.midX - calibratedNotch.midX) * widthEase
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
        let rect = drawingFrame(progress: progress)
        let local = CGPoint(x: point.x, y: screen.maxY - point.y)
        let topDown = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height)
        return IslandContour(rect: topDown, progress: progress, cornerAdjustment: shapeCalibration.corner, referenceDepth: notch.height).contains(local)
    }
    public func interactiveContains(_ point: CGPoint) -> Bool {
        let frame = drawingFrame(progress: 1)
        // Only the fully revealed content accepts clicks, not corners or hardware cutout.
        return CGRect(x: frame.minX + 16, y: frame.minY + 16,
            width: frame.width - 32, height: frame.height - notch.height - 28).contains(point)
    }
}
