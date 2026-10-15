import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Local, user-selected corrections in points. These are not model-specific hardware measurements.
public struct ContourCalibration: Equatable, Sendable {
    public let width: Double
    public let depth: Double
    public let corner: Double
    public init(width: Double = 0, depth: Double = 0, corner: Double = 0) {
        self.width = Self.step(width, limit: 16)
        self.depth = Self.step(depth, limit: 6)
        self.corner = Self.step(corner, limit: 6)
    }
    private static func step(_ value: Double, limit: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(limit, max(-limit, value)) * 2).rounded() / 2
    }
    public var isZero: Bool { self == ContourCalibration() }
}

/// Automatic circular profile, informed by the open-source Notchmeister 4/8 pt reference.
/// Reported depth normalizes display scaling (32 pt reference); this is an approximation,
/// not an Apple-published physical contour or a backing-pixel/model lookup table.
public struct IslandContour: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case move(CGPoint), line(CGPoint)
        case arc(center: CGPoint, radius: CGFloat, start: Double, end: Double, clockwise: Bool)
    }
    public let rect: CGRect
    public let shoulder: CGFloat
    public let corner: CGFloat
    public let upperCorner: CGFloat
    public init(rect: CGRect, progress: Double = 0, cornerAdjustment: Double = 0, referenceDepth: CGFloat = 32) {
        self.rect = rect
        let p = CGFloat(min(1, max(0, progress.isFinite ? progress : 0)))
        let scale = min(2, max(0.5, referenceDepth.isFinite ? referenceDepth / 32 : 1))
        shoulder = min(12 * p, max(0, rect.width / 4 - 2))
        let correction = ContourCalibration(corner: cornerAdjustment).corner
        let automaticLower = 8 * scale + 3 + CGFloat(correction)
        corner = min(max(4, automaticLower * (1 - p) + 24 * p),
                     max(4, min(rect.height / 2, (rect.width - 2 * shoulder) / 2)))
        // Cap the extra top flare to 0.5 pt: 3.5 pt geometric extent leaves
        // 0.5 pt for 1x antialiasing inside the established 4 pt paint envelope.
        upperCorner = min(min(0.5, max(0, 4 * scale - 3)) * (1 - p) + 12 * p,
                          max(0, rect.height - corner - 2))
    }
    /// Includes the small concave top flare, while side/bottom allowance remains 3 pt.
    public var bounds: CGRect {
        let flare = max(0, upperCorner - shoulder)
        return CGRect(x: rect.minX - flare, y: rect.minY, width: rect.width + 2 * flare, height: rect.height)
    }
    public func commands(inset: CGFloat = 0) -> [Command] {
        let i = min(2, max(0, inset))
        let left = rect.minX + shoulder + i, right = rect.maxX - shoulder - i
        let top = rect.minY, bottom = rect.maxY - i
        let upper = upperCorner + i, lower = max(0, corner - i)
        return [
            .move(CGPoint(x: left - upper, y: top)),
            .arc(center: CGPoint(x: left - upper, y: top + upper), radius: upper, start: -90, end: 0, clockwise: false),
            .line(CGPoint(x: left, y: bottom - lower)),
            .arc(center: CGPoint(x: left + lower, y: bottom - lower), radius: lower, start: 180, end: 90, clockwise: true),
            .line(CGPoint(x: right - lower, y: bottom)),
            .arc(center: CGPoint(x: right - lower, y: bottom - lower), radius: lower, start: 90, end: 0, clockwise: true),
            .line(CGPoint(x: right, y: top + upper)),
            .arc(center: CGPoint(x: right + upper, y: top + upper), radius: upper, start: 180, end: 270, clockwise: false)
        ]
    }
    public func contains(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        let y = point.y - rect.minY, left = rect.minX + shoulder, right = rect.maxX - shoulder
        if y < upperCorner, upperCorner > 0 {
            let dx = sqrt(max(0, upperCorner * upperCorner - pow(y - upperCorner, 2)))
            return point.x >= left - upperCorner + dx && point.x <= right + upperCorner - dx
        }
        guard point.x >= left, point.x <= right else { return false }
        if y > rect.height - corner {
            let cy = rect.maxY - corner
            if point.x < left + corner { return pow(point.x - left - corner, 2) + pow(point.y - cy, 2) <= corner * corner }
            if point.x > right - corner { return pow(point.x - right + corner, 2) + pow(point.y - cy, 2) <= corner * corner }
        }
        return true
    }
}
