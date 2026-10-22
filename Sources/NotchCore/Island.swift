import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One presentation owner resolves the existing island's target. Playback never
/// owns a second window or animation clock, and cannot replace an active notice.
public enum IslandExpansionOwner: Equatable, Sendable {
    case idle, music, quotaNotice, details

    public static func resolve(hoverExpanded: Bool, noticeActive: Bool,
                               musicEligible: Bool, passiveMusicAllowed: Bool) -> Self {
        if hoverExpanded { return .details }
        if noticeActive { return .quotaNotice }
        if musicEligible && passiveMusicAllowed { return .music }
        return .idle
    }

    public func target(compactProgress: Double) -> Double {
        switch self {
        case .idle: return 0
        case .details: return 1
        case .music, .quotaNotice:
            return compactProgress.isFinite ? min(1, max(0, compactProgress)) : 0
        }
    }
}

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
    public var collapsedSize: CGSize { frame(progress: 0).size }
    /// Optional visible music wings are not camera geometry or calibration.
    public var showsMusicAccessories = false
    /// Driven on the same frame clock as expansion, including playback edges.
    public var musicAccessoryProgress: Double = 1
    /// Latched only for a non-music idle -> hover interaction. Shared music geometry is the default.
    public var ordinaryHoverWidth = false
    /// A music-owned details excursion uses a direct path from its passive rest.
    /// The shared compact map still owns lyrics/notices. The panel latches this
    /// only at a settled endpoint and retains it through direction reversals.
    public var detailsWidthRestProgress: Double?
    public var widthPresentation: IslandWidthPresentation?
    public var expandedContentCenterX: CGFloat {
        var canonical = self; canonical.widthPresentation = nil
        return canonical.frame(progress: 1).minX + canonical.contourRect(progress: 1).midX
    }
    public var motionHorizontalBounds: ClosedRange<Double> {
        let scale = min(2, max(0.5, notch.height / 32))
        let flare = min(0.5, max(0, 4 * scale - 3))
        let left = ceil(screen.minX * backingScale) / backingScale
        let right = floor(screen.maxX * backingScale) / backingScale
        return Double(left + flare)...Double(right - flare)
    }
    public var expandedSize: CGSize { frame(progress: 1).size }
    public let contentHeight: CGFloat
    public let compactWidth: CGFloat
    public var compactContentWidth: CGFloat { max(1, compactWidth - 66) }
    public var noticeContentWidth: CGFloat { max(1, compactWidth - 36) }
    public var detailContentWidth: CGFloat { max(1, expandedContourFrame.width - 66) }
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
        let width = min(max(400, hardware.width + 40), screen.width - 24)
        self.compactWidth = min(width, max(360, hardware.width + 40))
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
    }
    public var updateProgress: Double { progress(forHeight: notch.height + 78) }
    /// The music target changes through the existing spring; the geometry map
    /// itself stays fixed, so cue wrapping never reinterprets an active frame.
    public func musicProgress(contentHeight: CGFloat) -> Double {
        let content = contentHeight.isFinite ? min(90, max(48, contentHeight)) : 48
        return progress(forHeight: notch.height + 16 + content)
    }
    private func progress(forHeight height: CGFloat) -> Double {
        let target = min(expandedContourFrame.height - 20, height)
        return Double(max(0.15, min(0.8, (target - contourFrame.height) / (expandedContourFrame.height - contourFrame.height))))
    }
    /// Maximum side/bottom/turn displacement from idle in one global point space.
    /// Native window pixel rounding is deliberately excluded from this paint input.
    public func contourResidual(progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        func contour(_ p: Double) -> IslandContour {
            let frame = drawingFrame(progress: p)
            return IslandContour(rect: CGRect(x: frame.minX, y: 0, width: frame.width, height: frame.height),
                progress: p, cornerAdjustment: shapeCalibration.corner, referenceDepth: notch.height)
        }
        let current = contour(progress)
        var reference = self; reference.widthPresentation = nil
        let idleFrame = reference.drawingFrame(progress: 0)
        let idle = IslandContour(rect: CGRect(x: idleFrame.minX, y: 0, width: idleFrame.width, height: idleFrame.height),
            progress: 0, cornerAdjustment: shapeCalibration.corner, referenceDepth: notch.height)
        let distances = [
            abs(current.rect.height - idle.rect.height),
            abs(current.rect.minX + current.shoulder - idle.rect.minX - idle.shoulder),
            abs(current.rect.maxX - current.shoulder - idle.rect.maxX + idle.shoulder),
            abs(current.bounds.minX - idle.bounds.minX), abs(current.bounds.maxX - idle.bounds.maxX),
            abs(current.corner - idle.corner), abs(current.upperCorner - idle.upperCorner)
        ]
        guard distances.allSatisfy({ $0.isFinite }) else { return 0 }
        return Double(distances.max() ?? 0)
    }
    /// Keep the same shrinking body visible until its contour is within four points
    /// of idle. The C1 fade is reversible and shares geometry, not another timer.
    /// The unchanged <0.001 spring snap leaves <2.2% alpha at the tallest card.
    public func surfaceOpacity(progress: Double) -> Double {
        let t = min(1, max(0, contourResidual(progress: progress) / 4))
        return t * t * (3 - 2 * t)
    }
    public func hasSameAnchor(as other: IslandGeometry) -> Bool {
        screen == other.screen && notch == other.notch && horizontalAdjustment == other.horizontalAdjustment
            && shapeCalibration == other.shapeCalibration && backingScale == other.backingScale
    }
    public func frame(progress: Double) -> CGRect {
        let contour = IslandContour(rect: drawingFrame(progress: progress), progress: progress, cornerAdjustment: shapeCalibration.corner, referenceDepth: notch.height).bounds
        return Self.nativeFrame(containing: contour, screen: screen, scale: backingScale)
    }
    /// Black side wings retain the hardware depth. The raw camera exclusion and
    /// original U path stay separate and unchanged; near-edge space fails closed.
    public var musicAccessoryFrame: CGRect {
        CGRect(x: max(screen.minX, calibratedNotch.minX - 34), y: screen.maxY - notch.height,
               width: min(screen.maxX, calibratedNotch.maxX + 34) - max(screen.minX, calibratedNotch.minX - 34),
               height: notch.height)
    }
    public var canShowMusicAccessories: Bool {
        calibratedNotch.minX - screen.minX >= 35 && screen.maxX - calibratedNotch.maxX >= 35
            && notch.height >= 20 && contourFrame.height >= notch.height
    }
    /// Fixed at the original hardware anchor, never at the moving card edge.
    public var musicGestureCorridor: CGRect {
        CGRect(x: musicAccessoryFrame.minX, y: contourFrame.minY,
               width: musicAccessoryFrame.width, height: contourFrame.height)
    }
    public func musicAccessoryRects(progress: Double) -> (left: CGRect, right: CGRect) {
        let native = frame(progress: progress)
        let y = CGFloat(0), depth = notch.height
        return (CGRect(x: calibratedNotch.minX - 34 - native.minX, y: y, width: 37, height: depth),
                CGRect(x: calibratedNotch.maxX - 3 - native.minX, y: y, width: 37, height: depth))
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
    /// Exact analytic width velocity; shared geometry is unchanged unless explicitly latched.
    public func widthSample(progress: Double, velocity: Double = 0, accessoryVelocity: Double = 0) -> IslandWidthSample {
        if let current = widthPresentation, current.progress == progress { return current.sample }
        let p = min(1, max(0, progress))
        if let rest = detailsWidthRestProgress, rest.isFinite, rest >= 0, rest < 1, p >= rest {
            var canonical = self
            canonical.detailsWidthRestProgress = nil; canonical.widthPresentation = nil
            canonical.ordinaryHoverWidth = false
            let origin = canonical.widthSample(progress: rest, accessoryVelocity: accessoryVelocity)
            let full = canonical.widthSample(progress: 1)
            let t = min(1, max(0, (p - rest) / (1 - rest)))
            // Both raw width and center are affine in the SAME height progress.
            // The visible sides subtract 12*p each, so their span is affine too,
            // including wide music shells that must narrow toward the full card.
            // Keep the original accessory derivative instead of freezing a wing
            // that is still appearing when hover begins at p=0.
            let rate = velocity / (1 - rest)
            return IslandWidthSample(width: origin.width + (full.width - origin.width) * t,
                center: origin.center + (full.center - origin.center) * t,
                widthVelocity: origin.widthVelocity * (1 - t) + (full.width - origin.width) * rate,
                centerVelocity: origin.centerVelocity * (1 - t) + (full.center - origin.center) * rate)
        }
        func ease(_ q: Double) -> (Double, Double) {
            if q <= 0 { return (0, 0) }; if q >= 1 { return (1, 0) }
            return (q * q * (3 - 2 * q), 6 * q * (1 - q))
        }
        let base = Double(contourFrame.width), full = Double(expandedContourFrame.width)
        let c0 = Double(calibratedNotch.midX), dc = Double(expandedContourFrame.midX - calibratedNotch.midX)
        if ordinaryHoverWidth {
            let q = ease(p / updateProgress)
            return IslandWidthSample(width: base + (full - base) * q.0, center: c0 + dc * q.0,
                widthVelocity: (full - base) * q.1 / updateProgress * velocity,
                centerVelocity: dc * q.1 / updateProgress * velocity)
        }
        let a = showsMusicAccessories ? min(1, max(0, musicAccessoryProgress)) : 0
        let wing = Double(musicAccessoryFrame.width) - base
        let closed = base + wing * a, compact = Double(compactWidth)
        let lower = musicProgress(contentHeight: 48), upper = musicProgress(contentHeight: 90)
        let q = ease(p / lower), d = ease((p - upper) / (1 - upper))
        return IslandWidthSample(width: closed + (compact - closed) * q.0 + (full - compact) * d.0,
            center: c0 + dc * q.0,
            widthVelocity: (compact - closed) * q.1 / lower * velocity
                + (full - compact) * d.1 / (1 - upper) * velocity
                + (showsMusicAccessories ? wing * accessoryVelocity * (1 - q.0) : 0),
            centerVelocity: dc * q.1 / lower * velocity)
    }
    private func drawingFrame(progress: Double) -> CGRect {
        if ordinaryHoverWidth || detailsWidthRestProgress != nil || widthPresentation?.progress == progress {
            let p = min(1, max(0, progress.isFinite ? progress : 0))
            let value = widthSample(progress: p)
            let height = contourFrame.height + (expandedContourFrame.height - contourFrame.height) * CGFloat(p)
            return CGRect(x: CGFloat(value.center - value.width / 2), y: screen.maxY - height,
                width: CGFloat(value.width), height: height)
        }
        let p = CGFloat(min(1, max(0, progress.isFinite ? progress : 0)))
        let accessory = showsMusicAccessories ? CGFloat(min(1, max(0, musicAccessoryProgress))) : 0
        let closedWidth = contourFrame.width + (musicAccessoryFrame.width - contourFrame.width) * accessory
        let closed = CGRect(x: contourFrame.midX - closedWidth / 2, y: contourFrame.minY, width: closedWidth, height: contourFrame.height)
        if p == 0 { return closed }
        if p == 1 { return expandedContourFrame }
        // Reach one shared compact width, retain it through all music/notice
        // heights, then grow toward details. This map never depends on text.
        let lower = CGFloat(musicProgress(contentHeight: 48))
        let upper = CGFloat(musicProgress(contentHeight: 90))
        func ease(_ value: CGFloat) -> CGFloat {
            let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
        }
        let compactEase = ease(p / lower)
        let detailEase = ease((p - upper) / (1 - upper))
        let width = closedWidth + (compactWidth - closedWidth) * compactEase
            + (expandedContourFrame.width - compactWidth) * detailEase
        let height = contourFrame.height + (expandedContourFrame.height - contourFrame.height) * p
        let center = calibratedNotch.midX + (expandedContourFrame.midX - calibratedNotch.midX) * compactEase
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
    /// Gesture reservation uses the stable full endpoint, not an interrupted presentation.
    public func canonicalHoverContains(_ point: CGPoint, progress: Double) -> Bool {
        var value = self; value.widthPresentation = nil; value.detailsWidthRestProgress = nil
        return value.hoverContains(point, progress: progress)
    }
    public func hoverContains(_ point: CGPoint, progress: Double,
                              retainingMusicOrigin: Bool = false) -> Bool {
        // A wide closed music shell can extend beyond the narrower compact
        // transition or the full card's inset shoulders. Once hover owns details,
        // animation alone must not evict its stationary activation point. Retain
        // only that closed shell, not the whole expanded rectangle; click and
        // gesture hit testing continue to use their existing exact geometry.
        if retainingMusicOrigin && showsMusicAccessories && canShowMusicAccessories {
            var origin = self
            origin.widthPresentation = nil
            origin.ordinaryHoverWidth = false
            origin.detailsWidthRestProgress = nil
            if origin.hoverContains(point, progress: 0) { return true }
        }
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
