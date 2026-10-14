import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class IslandTests: XCTestCase {
    func testHoverRequiresDwellAndCancelsFlyby() {
        var state = IslandHoverState()
        state.update(inside: true, now: 0)
        state.update(inside: false, now: 0.08)
        state.update(inside: true, now: 1)
        state.update(inside: true, now: 1.11)
        XCTAssertFalse(state.isExpanded)
        state.update(inside: true, now: 1.13)
        XCTAssertTrue(state.isExpanded)
    }
    func testExitGraceAndReentryCancelCollapse() {
        var state = IslandHoverState()
        state.update(inside: true, now: 0); state.update(inside: true, now: 0.2)
        state.update(inside: false, now: 0.3); state.update(inside: true, now: 0.4)
        state.update(inside: false, now: 1); state.update(inside: false, now: 1.21)
        XCTAssertTrue(state.isExpanded)
        state.update(inside: false, now: 1.23)
        XCTAssertFalse(state.isExpanded)
    }
    func testScreenChangeResetsPendingAndOpenState() {
        var state = IslandHoverState()
        state.update(inside: true, now: 0); state.update(inside: true, now: 1)
        state.reset(); XCTAssertFalse(state.isExpanded)
        state.update(inside: true, now: 1.01); XCTAssertFalse(state.isExpanded)
    }
    func testSpringConvergesAndStaysBoundedAcrossReversal() {
        var motion = IslandMotion()
        for _ in 0..<12 { motion.advance(expanded: true, elapsed: 1.0 / 60, reduceMotion: false) }
        let before = motion.progress
        XCTAssertGreaterThan(before, 0); XCTAssertLessThan(before, 1)
        motion.advance(expanded: false, elapsed: 1.0 / 60, reduceMotion: false)
        XCTAssertLessThan(abs(motion.progress - before), 0.1)
        for _ in 0..<120 {
            motion.advance(expanded: false, elapsed: 1.0 / 60, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(motion.progress, 0); XCTAssertLessThanOrEqual(motion.progress, 1)
        }
        XCTAssertEqual(motion.progress, 0); XCTAssertTrue(motion.isSettled)
    }
    func testReduceMotionJumpsWithoutResidualVelocity() {
        var motion = IslandMotion()
        motion.advance(expanded: true, elapsed: 0.1, reduceMotion: false)
        motion.advance(expanded: true, elapsed: 0.1, reduceMotion: true)
        XCTAssertEqual(motion.progress, 1); XCTAssertEqual(motion.velocity, 0)
        motion.advance(expanded: false, elapsed: 0.1, reduceMotion: true)
        XCTAssertEqual(motion.progress, 0)
    }
    func testActualTopAnchorAtEveryIntermediateSizeOnNegativeScreen() throws {
        let screen = CGRect(x: -1512, y: 982, width: 1512, height: 982)
        let notch = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32,
            auxiliaryLeft: CGRect(x: -1512, y: 1932, width: 646, height: 32),
            auxiliaryRight: CGRect(x: -646, y: 1932, width: 646, height: 32)))
        let island = IslandGeometry(notch: notch, screen: screen)
        for p in stride(from: 0.0, through: 1.0, by: 0.01) {
            let frame = island.frame(progress: p)
            XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.0001)
            XCTAssertEqual(frame.midX, notch.notch.midX, accuracy: 0.0001)
            XCTAssertTrue(screen.insetBy(dx: -0.001, dy: -0.001).contains(frame))
        }
        XCTAssertFalse(island.interactiveContains(CGPoint(x: notch.notch.midX, y: screen.maxY - 4)))
        XCTAssertTrue(island.interactiveContains(CGPoint(x: notch.notch.midX, y: screen.maxY - 150)))
    }
}
