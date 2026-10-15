import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class ContourTests: XCTestCase {
    private func geometry(width: Double = 220, depth: Double = 32, offset: Double = 0,
                          scale: Double = 2, profile: ContourCalibration = .init()) -> IslandGeometry {
        let screen = CGRect(x: -900, y: 400, width: 1440, height: 900)
        let left = screen.midX - width / 2 + 30.125, right = left + width
        let raw = NotchGeometry.calculate(screen: screen, topInset: depth,
            auxiliaryLeft: CGRect(x: screen.minX, y: screen.maxY-depth, width: left-screen.minX, height: depth),
            auxiliaryRight: CGRect(x: right, y: screen.maxY-depth, width: screen.maxX-right, height: depth))!
        return IslandGeometry(notch: raw, screen: screen, backingScale: scale, horizontalAdjustment: offset, shapeCalibration: profile)
    }
    func testProfileFiniteBoundedHalfPointDefaults() {
        XCTAssertEqual(ContourCalibration(), ContourCalibration(width: 0, depth: 0, corner: 0))
        XCTAssertEqual(ContourCalibration(width: 100, depth: -100, corner: 100), .init(width: 16, depth: -6, corner: 6))
        XCTAssertEqual(ContourCalibration(width: .nan, depth: .infinity, corner: -.infinity), .init())
        XCTAssertEqual(ContourCalibration(width: 1.24, depth: -0.74, corner: 2.26), .init(width: 1, depth: -0.5, corner: 2.5))
    }
    func testTotalWidthMovesEachSideByHalfAndPreservesRawExclusion() {
        let base = geometry(), changed = geometry(profile: .init(width: 16))
        XCTAssertEqual(changed.notch, base.notch)
        XCTAssertEqual(changed.contourFrame.minX, base.contourFrame.minX - 8)
        XCTAssertEqual(changed.contourFrame.maxX, base.contourFrame.maxX + 8)
        XCTAssertEqual(changed.contourFrame.midX, base.contourFrame.midX)
        XCTAssertEqual(changed.contourFrame.height, base.contourFrame.height)
    }
    func testDepthMovesBottomOnlyAndCornerDoesNotChangeEnvelope() {
        let base = geometry(), depth = geometry(profile: .init(depth: 6)), curve = geometry(profile: .init(corner: 6))
        XCTAssertEqual(depth.contourFrame.minY, base.contourFrame.minY - 6)
        XCTAssertEqual(depth.contourFrame.maxY, base.contourFrame.maxY)
        XCTAssertEqual(curve.contourFrame, base.contourFrame)
        XCTAssertNotEqual(IslandContour(rect: curve.contourRect(progress: 0), cornerAdjustment: 6).commands(),
                          IslandContour(rect: base.contourRect(progress: 0)).commands())
    }
    func testAutomaticCircularReferenceAndInsetShareCenters() {
        let contour = IslandContour(rect: CGRect(x: 0, y: 0, width: 226, height: 35))
        XCTAssertEqual(contour.corner, 11) // 8 pt reference + 3 pt outer allowance.
        XCTAssertEqual(contour.upperCorner, 0.5) // Bounded top flare, not an extra wing.
        let commands = contour.commands(inset: 2)
        XCTAssertEqual(commands[0], .move(CGPoint(x: -0.5, y: 0)))
        XCTAssertEqual(commands[2], .line(CGPoint(x: 2, y: 24)))
        XCTAssertEqual(commands[3], .arc(center: CGPoint(x: 11, y: 24), radius: 9, start: 180, end: 90, clockwise: true))
        XCTAssertEqual(contour.commands()[3], .arc(center: CGPoint(x: 11, y: 24), radius: 11, start: 180, end: 90, clockwise: true))
    }
    func testAutomaticReferenceTracksReportedDepthNotBackingScale() {
        for depth in [22.0, 28, 32, 38] {
            let one = geometry(depth: depth, scale: 1), two = geometry(depth: depth, scale: 2)
            let a = IslandContour(rect: one.contourRect(progress: 0), referenceDepth: depth)
            let b = IslandContour(rect: two.contourRect(progress: 0), referenceDepth: depth)
            XCTAssertEqual(a.corner, b.corner)
            XCTAssertEqual(a.corner, 8 * depth / 32 + 3)
            XCTAssertLessThanOrEqual(a.upperCorner, 0.5)
        }
    }
    func testCombinedExtremesStayBoundedAndRestoreAtOneAndTwoX() {
        for scale in [1.0, 2] { for width in [-16.0, 0, 16] { for depth in [-6.0, 0, 6] { for corner in [-6.0, 0, 6] {
            let value = geometry(width: 219.5, offset: 8, scale: scale, profile: .init(width: width, depth: depth, corner: corner))
            let idle = value.frame(progress: 0)
            for p in [0.0, 0.001, 0.05, 0.25, 0.5, 0.75, 1] {
                let native = value.frame(progress: p), rect = value.contourRect(progress: p)
                XCTAssertTrue(value.screen.contains(native))
                XCTAssertEqual(native.maxY, value.screen.maxY)
                XCTAssertTrue(CGRect(origin: .zero, size: native.size).insetBy(dx: -0.001, dy: -0.001).contains(rect))
                let contour = IslandContour(rect: rect, progress: p, cornerAdjustment: corner)
                XCTAssertGreaterThanOrEqual(contour.corner, 4)
                XCTAssertLessThanOrEqual(2 * (contour.shoulder + contour.corner), rect.width + 0.001)
                XCTAssertLessThanOrEqual(contour.shoulder + contour.corner, rect.height + 0.001)
            }
            XCTAssertEqual(value.frame(progress: 0), idle)
        }}}}
    }
    func testSmallCorrectedCutoutCannotReverseTurns() {
        let value = geometry(width: 24, depth: 10, profile: .init(width: -16, depth: -6, corner: 6))
        let contour = IslandContour(rect: value.contourRect(progress: 0), cornerAdjustment: 6)
        XCTAssertGreaterThanOrEqual(contour.rect.width, 24)
        XCTAssertGreaterThanOrEqual(contour.rect.height, 12)
        XCTAssertLessThanOrEqual(contour.corner, contour.rect.height / 2)
        XCTAssertLessThanOrEqual(contour.corner * 2, contour.rect.width)
    }
    func testCorrectionRemainsSeparateFromCameraSafeContentArea() {
        let value = geometry(profile: .init(width: -16, depth: -6, corner: -6))
        let rawCenter = CGPoint(x: value.notch.midX, y: value.notch.midY)
        XCTAssertFalse(value.interactiveContains(rawCenter))
        XCTAssertTrue(value.hoverContains(CGPoint(x: value.calibratedNotch.midX, y: value.contourFrame.minY + 1), progress: 0))
    }
    func testNearEdgeCorrectionIncludesCurvedEnvelopeAndBackingGrid() {
        for scale in [CGFloat(1), CGFloat(2)] {
            let screen = CGRect(x: -1024, y: -768, width: 1024, height: 768)
            for rightSide in [false, true] {
                let left = rightSide ? screen.maxX - 224.25 : screen.minX + 4.25
                let raw = NotchGeometry(notch: CGRect(x: left, y: screen.maxY - 32, width: 220, height: 32), leftPanel: .zero, rightPanel: .zero)
                for width in [-16.0, 0, 16] {
                    let value = IslandGeometry(notch: raw, screen: screen, backingScale: scale,
                        horizontalAdjustment: rightSide ? 8 : -8, shapeCalibration: .init(width: width))
                    for p in [0.0, 0.01, 0.2, 0.5, 1] {
                        XCTAssertTrue(screen.contains(value.frame(progress: p)))
                    }
                    XCTAssertEqual(value.notch, raw.notch)
                }
            }
        }
    }
    func testCompactEndpointsKeepIdleAnchorAndPillHeightAcrossContentChanges() {
        let base = geometry()
        let raw = NotchGeometry(notch: base.notch, leftPanel: .zero, rightPanel: .zero)
        let compact = IslandGeometry(notch: raw, screen: base.screen, contentHeight: 180)
        let many = IslandGeometry(notch: raw, screen: base.screen, contentHeight: 340)
        XCTAssertTrue(compact.hasSameAnchor(as: many))
        XCTAssertEqual(compact.frame(progress: 0), many.frame(progress: 0))
        XCTAssertEqual(compact.frame(progress: compact.updateProgress).height, 110)
        XCTAssertEqual(many.frame(progress: many.updateProgress).height, 110)
        XCTAssertEqual(compact.contentHeight, 180)
        XCTAssertEqual(compact.expandedSize.height, 220)
    }

}
