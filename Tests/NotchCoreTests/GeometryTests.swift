import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class GeometryTests: XCTestCase {
    func testGlobalCoordinatesOnOffsetScreen() throws {
        let screen = CGRect(x: -1728, y: 200, width: 1728, height: 1117)
        let left = CGRect(x: -1728, y: 1285, width: 754, height: 32)
        let right = CGRect(x: -754, y: 1285, width: 754, height: 32)
        let result = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32, auxiliaryLeft: left, auxiliaryRight: right))
        XCTAssertEqual(result.notch, CGRect(x: -974, y: 1285, width: 220, height: 32))
        XCTAssertEqual(result.leftPanel.maxX, result.rightPanel.minX)
        XCTAssertEqual(result.leftPanel.minY, 1278)
        XCTAssertEqual(result.rightPanel.maxY, screen.maxY)
        let detail = result.detailFrame(size: CGSize(width: 340, height: 400), screen: screen)
        XCTAssertTrue(screen.contains(detail))
        XCTAssertLessThan(detail.maxY, result.notch.minY)
    }
    func testNoNotchUsesNoOverlay() {
        XCTAssertNil(NotchGeometry.calculate(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0, auxiliaryLeft: nil, auxiliaryRight: nil))
    }
    func testInvalidAuxiliaryRectsRejected() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertNil(NotchGeometry.calculate(screen: screen, topInset: 32, auxiliaryLeft: CGRect(x: 0, y: 0, width: 800, height: 32), auxiliaryRight: CGRect(x: 900, y: 0, width: 828, height: 32)))
    }
    func testFractionalScalingAndVerticalDisplayArrangement() throws {
        let screen = CGRect(x: 100, y: 1200, width: 1512, height: 982)
        let result = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32,
            auxiliaryLeft: CGRect(x: 100, y: 2150, width: 646.25, height: 32),
            auxiliaryRight: CGRect(x: 966.25, y: 2150, width: 645.75, height: 32), scale: 2))
        XCTAssertEqual(result.notch.minX, 746.25)
        XCTAssertEqual(result.notch.maxX, 966.25)
        XCTAssertEqual(result.notch.midX, 856.25)
        XCTAssertEqual(result.notch.minY, 2150)
    }
    func testAuxiliaryEdgesAndInsetRemainRawAtEveryScale() throws {
        for origin in [CGPoint(x: 100, y: 1200), CGPoint(x: -1612, y: -982)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
            let left = CGRect(x: screen.minX, y: screen.maxY - 32.125, width: 646.125, height: 32.125)
            let right = CGRect(x: screen.minX + 866.375, y: left.minY, width: 645.625, height: 32.125)
            for scale in [1.0, 2.0, 0.0, -1.0, .infinity, .nan] {
                let result = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32.125,
                    auxiliaryLeft: left, auxiliaryRight: right, scale: scale))
                XCTAssertEqual(result.notch.minX, left.maxX)
                XCTAssertEqual(result.notch.maxX, right.minX)
                XCTAssertEqual(result.notch.midX, (left.maxX + right.minX) / 2)
                XCTAssertEqual(result.notch.minY, screen.maxY - 32.125)
                XCTAssertEqual(result.notch.height, 32.125)
                XCTAssertEqual(result.notch.maxY, screen.maxY)
                XCTAssertEqual(result.leftPanel.maxX, result.notch.midX)
                XCTAssertEqual(result.rightPanel.minX, result.notch.midX)
            }
        }
    }
    func testRoundingHardwareEdgesUsedToAddHalfABackingPixel() throws {
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
        for scale in [1.0, 2.0] {
            let leftEdge = 402 + 0.5 / scale
            let rightEdge = leftEdge + 220
            let result = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32,
                auxiliaryLeft: CGRect(x: 0, y: 736, width: leftEdge, height: 32),
                auxiliaryRight: CGRect(x: rightEdge, y: 736, width: 1024 - rightEdge, height: 32), scale: scale))
            let rawMidpoint = (leftEdge + rightEdge) / 2
            let oldRoundedMidpoint = ((leftEdge * scale).rounded() + (rightEdge * scale).rounded()) / (2 * scale)
            XCTAssertEqual(oldRoundedMidpoint - rawMidpoint, 0.5 / scale)
            XCTAssertEqual(result.notch.midX, rawMidpoint)
        }
    }
    func testBackoffAndHoverDebounce() {
        var policy = RefreshPolicy()
        XCTAssertEqual(policy.delay, 60)
        policy.failed(); XCTAssertEqual(policy.delay, 120)
        for _ in 0..<20 { policy.failed() }
        XCTAssertEqual(policy.delay, 900)
        policy.succeeded(); XCTAssertEqual(policy.delay, 60)
        XCTAssertFalse(RefreshPolicy.shouldRefreshOnHover(lastAttempt: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: 129)))
        XCTAssertTrue(RefreshPolicy.shouldRefreshOnHover(lastAttempt: Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: 130)))
    }
}
