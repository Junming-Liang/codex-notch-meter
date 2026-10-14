import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// All input and output rectangles use AppKit global screen coordinates in points.
public struct NotchGeometry: Equatable, Sendable {
    public let notch: CGRect
    public let leftPanel: CGRect
    public let rightPanel: CGRect

    public static func calculate(screen: CGRect, topInset: Double, auxiliaryLeft: CGRect?, auxiliaryRight: CGRect?, scale: Double = 2) -> NotchGeometry? {
        guard topInset > 0, topInset < Double(screen.height) / 2,
              let left = auxiliaryLeft, let right = auxiliaryRight,
              left.width > 0, right.width > 0,
              left.maxX < right.minX,
              left.minX >= screen.minX - 1, right.maxX <= screen.maxX + 1,
              abs(left.maxY - screen.maxY) < 2, abs(right.maxY - screen.maxY) < 2 else { return nil }
        let pixelScale = scale > 0 && scale.isFinite ? scale : 1
        func align(_ value: CGFloat) -> CGFloat { (value * pixelScale).rounded() / pixelScale }
        let x = align(left.maxX), y = align(screen.maxY - topInset)
        let width = align(right.minX) - x
        guard width > 0, width < screen.width / 2 else { return nil }
        let notch = CGRect(x: x, y: y, width: width, height: align(topInset))
        let wing: CGFloat = 6, bottom: CGFloat = 7
        let middle = align(notch.midX)
        return NotchGeometry(
            notch: notch,
            leftPanel: CGRect(x: notch.minX - wing, y: notch.minY - bottom, width: middle - notch.minX + wing, height: notch.height + bottom),
            rightPanel: CGRect(x: middle, y: notch.minY - bottom, width: notch.maxX - middle + wing, height: notch.height + bottom)
        )
    }
    public func detailFrame(size: CGSize, screen: CGRect) -> CGRect {
        let margin: CGFloat = 12
        let width = min(size.width, screen.width - 2 * margin)
        let height = min(size.height, screen.height - notch.height - 2 * margin)
        return CGRect(x: min(max(notch.midX - width / 2, screen.minX + margin), screen.maxX - width - margin),
                      y: max(screen.minY + margin, notch.minY - height - 12), width: width, height: height)
    }
}

public struct RefreshPolicy: Equatable, Sendable {
    public private(set) var failures: Int = 0
    public init() {}
    public mutating func succeeded() { failures = 0 }
    public mutating func failed() { failures = min(failures + 1, 5) }
    public var delay: TimeInterval { failures == 0 ? 60 : min(60 * pow(2, Double(failures)), 900) }
    public static func shouldRefreshOnHover(lastAttempt: Date?, now: Date) -> Bool {
        lastAttempt.map { now.timeIntervalSince($0) >= 30 } ?? true
    }
}
