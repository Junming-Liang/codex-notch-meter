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
        XCTAssertEqual(result.notch.minX * 2, (result.notch.minX * 2).rounded())
        XCTAssertEqual(result.notch.minY, 2150)
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
