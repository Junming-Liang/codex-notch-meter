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
    func testIntermediateFramesAlignBeforeNativeRoundingAtOneAndTwoTimesScale() throws {
        for scale in [CGFloat(1), CGFloat(2)] {
            for origin in [CGPoint.zero, CGPoint(x: -1024, y: 768)] {
                let screen = CGRect(origin: origin, size: CGSize(width: 1024, height: 768))
                let notch = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32,
                    auxiliaryLeft: CGRect(x: screen.minX, y: screen.maxY - 32, width: 402, height: 32),
                    auxiliaryRight: CGRect(x: screen.minX + 622, y: screen.maxY - 32, width: 402, height: 32), scale: scale))
                let island = IslandGeometry(notch: notch, screen: screen, backingScale: scale)
                for step in 0...100 {
                    let frame = island.frame(progress: Double(step) / 100)
                    for value in [frame.minX, frame.minY, frame.width, frame.height] {
                        XCTAssertEqual(value * scale, (value * scale).rounded(), accuracy: 0.0001)
                    }
                    XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.0001)
                    XCTAssertEqual(frame.midX, notch.notch.midX, accuracy: 0.5 / scale)
                    XCTAssertTrue(screen.contains(frame))
                }
                if scale == 1 && origin == .zero {
                    // Run #6 exposed AppKit rounding these formerly fractional frames.
                    XCTAssertEqual(island.frame(progress: 0.65), CGRect(x: 347, y: 421, width: 330, height: 347))
                    XCTAssertEqual(island.frame(progress: 0.8), CGRect(x: 336, y: 350, width: 352, height: 418))
                }
            }
        }
    }
}
