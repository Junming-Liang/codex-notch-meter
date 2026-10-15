import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// All input and output rectangles use AppKit global screen coordinates in points.
public struct NotchGeometry: Equatable, Sendable {
    public let notch: CGRect
    public let leftPanel: CGRect
    public let rightPanel: CGRect

    public static func calculate(screen: CGRect, topInset: Double, auxiliaryLeft: CGRect?, auxiliaryRight: CGRect?, scale _: Double = 2) -> NotchGeometry? {
        func finitePositive(_ rect: CGRect) -> Bool {
            [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
                && rect.size.width > 0 && rect.size.height > 0
        }
        guard finitePositive(screen), topInset.isFinite, topInset > 0, topInset < Double(screen.height) / 2,
              let left = auxiliaryLeft, let right = auxiliaryRight,
              finitePositive(left), finitePositive(right),
              screen.insetBy(dx: -0.001, dy: -0.001).contains(left),
              screen.insetBy(dx: -0.001, dy: -0.001).contains(right),
              left.maxX < right.minX,
              abs(left.maxY - screen.maxY) < 0.001, abs(right.maxY - screen.maxY) < 0.001,
              left.minY >= screen.maxY - topInset - 0.001,
              right.minY >= screen.maxY - topInset - 0.001 else { return nil }
        // Auxiliary edges describe system-reported camera exclusion bounds, not a native window.
        // Keep them exact; backing-grid normalization belongs to window placement.
        // The scale argument remains accepted for source compatibility.
        let x = left.maxX, y = screen.maxY - topInset
        let width = right.minX - x
        guard width > 0, width < screen.width / 2 else { return nil }
        let notch = CGRect(x: x, y: y, width: width, height: topInset)
        let wing: CGFloat = 6, bottom: CGFloat = 7
        let middle = notch.midX
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
