import XCTest
@testable import NotchCore

final class UpdateMotionTests: XCTestCase {
    func testIntermediateTargetSettlesThenRetargetsContinuously() {
        var motion = IslandMotion()
        for _ in 0..<120 { motion.advance(target: 0.4, elapsed: 1.0 / 60, reduceMotion: false) }
        XCTAssertTrue(motion.isSettled(at: 0.4)); XCTAssertEqual(motion.progress, 0.4)
        let before = motion
        motion.advance(target: 1, elapsed: 0, reduceMotion: false)
        XCTAssertEqual(motion, before)
        motion.advance(target: 1, elapsed: 0.02, reduceMotion: false)
        XCTAssertGreaterThan(motion.progress, 0.4)
        let closing = motion
        motion.advance(target: 0, elapsed: 0, reduceMotion: false)
        XCTAssertEqual(motion, closing)
        for _ in 0..<120 { motion.advance(target: 0, elapsed: 1.0 / 60, reduceMotion: false) }
        XCTAssertTrue(motion.isSettled(at: 0))
    }
    func testIntermediateReduceMotionAndInvalidTargets() {
        var motion = IslandMotion()
        motion.advance(target: 0.37, elapsed: 0, reduceMotion: true)
        XCTAssertTrue(motion.isSettled(at: 0.37))
        let before = motion
        for target in [Double.nan, .infinity, -.infinity] {
            motion.advance(target: target, elapsed: 1, reduceMotion: true)
            XCTAssertEqual(motion, before)
        }
    }
    func testIntermediateTrajectoryIndependentOfPartition() {
        var full = IslandMotion(), split = IslandMotion()
        full.advance(target: 0.4, elapsed: 0.2, reduceMotion: false)
        for _ in 0..<20 { split.advance(target: 0.4, elapsed: 0.01, reduceMotion: false) }
        XCTAssertEqual(full.progress, split.progress, accuracy: 1e-12)
        XCTAssertEqual(full.velocity, split.velocity, accuracy: 1e-12)
    }
    func testFractionalFormattingCannotClaimZeroConsumption() {
        XCTAssertEqual(QuotaFormatting.points(0.004), "<0.01")
        XCTAssertEqual(QuotaFormatting.points(0.01), "0.01")
        XCTAssertEqual(QuotaFormatting.points(3), "3")
        XCTAssertEqual(QuotaFormatting.points(10), "10")
        XCTAssertEqual(QuotaFormatting.percent(80.25), "80.25%")
        XCTAssertEqual(QuotaFormatting.percent(100), "100%")
        XCTAssertEqual(QuotaFormatting.percent(.nan), "—")
    }
}
