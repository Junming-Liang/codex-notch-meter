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
    func testMidCollapseReentryResumesWithoutInitialDwell() {
        var state = IslandHoverState()
        state.update(inside: true, now: 0)
        state.update(inside: true, now: 0.13)
        state.update(inside: false, now: 0.2)
        state.update(inside: false, now: 0.43)
        XCTAssertFalse(state.isExpanded)
        state.update(inside: true, now: 0.44, resumeExpanded: true)
        XCTAssertTrue(state.isExpanded)
    }
    func testGracePeriodReentryDoesNotNeedResumeHintOrAnotherDwell() {
        var state = IslandHoverState()
        state.update(inside: true, now: 0)
        state.update(inside: true, now: 0.13)
        state.update(inside: false, now: 0.2)
        state.update(inside: true, now: 0.3)
        XCTAssertTrue(state.isExpanded)
        state.update(inside: false, now: 0.31)
        state.update(inside: false, now: 0.52)
        XCTAssertTrue(state.isExpanded)
        state.update(inside: false, now: 0.54)
        XCTAssertFalse(state.isExpanded)
    }
    func testResumeHintIsIgnoredOutsideAndDoesNotBypassNextInitialDwell() {
        var state = IslandHoverState()
        state.update(inside: false, now: 0, resumeExpanded: true)
        XCTAssertFalse(state.isExpanded)
        state.update(inside: true, now: 0.01)
        XCTAssertFalse(state.isExpanded)
        state.update(inside: false, now: 0.08)
        state.update(inside: true, now: 1)
        state.update(inside: true, now: 1.11)
        XCTAssertFalse(state.isExpanded)
        state.update(inside: true, now: 1.13)
        XCTAssertTrue(state.isExpanded)
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
    func testSpringMatchesCriticalResponseAndConsumesWholeInterval() {
        var motion = IslandMotion()
        motion.advance(expanded: true, elapsed: 0.2, reduceMotion: false)
        // Independent closed-form reference for a unit step at 16 rad/s.
        XCTAssertEqual(motion.progress, 0.8287987432908619, accuracy: 1e-12)
        XCTAssertEqual(motion.velocity, 2.08702484369235, accuracy: 1e-12)
    }
    func testReferenceInformedMotionMilestonesRemainIndependentOfNoticeDwell() {
        // Solve the analytical unit step independently at1ms resolution. These are
        // point/progress timings, not display FPS or equivalence to Apple's spring.
        for expanded in [false, true] {
            var motion = IslandMotion()
            motion.advance(expanded: !expanded, elapsed: 0, reduceMotion: true)
            var time95: Double?, time99: Double?
            for tick in 1...1_000 {
                motion.advance(expanded: expanded, elapsed: 0.001, reduceMotion: false)
                let residual = abs((expanded ? 1.0 : 0.0) - motion.progress)
                if residual <= 0.05 && time95 == nil { time95 = Double(tick) / 1_000 }
                if residual <= 0.01 && time99 == nil { time99 = Double(tick) / 1_000 }
            }
            XCTAssertEqual(time95 ?? -1, 0.297, accuracy: 0.001)
            XCTAssertEqual(time99 ?? -1, 0.415, accuracy: 0.001)
            for duration in NoticeDuration.allCases { XCTAssertGreaterThan(duration.seconds, time99 ?? 1) }
        }
    }
    func testSpringIsIndependentOfCadenceAndIntervalPartition() {
        // Every cadence reaches exactly the same target-change times, including
        // irregular final ticks; no comparison relies on a rounded frame count.
        let segments: [(expanded: Bool, duration: Double)] = [
            (true, 0.12), (false, 0.035), (true, 0.045), (false, 0.2)
        ]
        var reference = IslandMotion()
        for segment in segments {
            reference.advance(expanded: segment.expanded, elapsed: segment.duration, reduceMotion: false)
        }
        for cadence in [24.0, 30, 60, 120, 144, 240] {
            var motion = IslandMotion()
            for segment in segments {
                var remaining = segment.duration
                while remaining > 0 {
                    let elapsed = min(1 / cadence, remaining)
                    motion.advance(expanded: segment.expanded, elapsed: elapsed, reduceMotion: false)
                    remaining -= elapsed
                }
            }
            XCTAssertEqual(motion.progress, reference.progress, accuracy: 1e-11, "cadence=\(cadence)")
            XCTAssertEqual(motion.velocity, reference.velocity, accuracy: 1e-11, "cadence=\(cadence)")
        }
        var irregular = IslandMotion()
        for elapsed in [0.001, 0.027, 0.002, 0.091, 0.079] {
            irregular.advance(expanded: true, elapsed: elapsed, reduceMotion: false)
        }
        var single = IslandMotion()
        single.advance(expanded: true, elapsed: 0.2, reduceMotion: false)
        XCTAssertEqual(irregular.progress, single.progress, accuracy: 1e-12)
        XCTAssertEqual(irregular.velocity, single.velocity, accuracy: 1e-12)
    }
    func testSpringReversalPreservesPositionAndVelocityInBothDirections() {
        for initiallyExpanded in [false, true] {
            var motion = IslandMotion()
            motion.advance(expanded: initiallyExpanded, elapsed: 0, reduceMotion: true)
            motion.advance(expanded: !initiallyExpanded, elapsed: 0.1, reduceMotion: false)
            let before = motion
            motion.advance(expanded: initiallyExpanded, elapsed: 0, reduceMotion: false)
            XCTAssertEqual(motion, before)
            let epsilon = 1e-6
            motion.advance(expanded: initiallyExpanded, elapsed: epsilon, reduceMotion: false)
            // A new target changes acceleration, not instantaneous velocity.
            XCTAssertEqual((motion.progress - before.progress) / epsilon, before.velocity, accuracy: 0.001)
            XCTAssertEqual(motion.velocity, before.velocity, accuracy: 0.001)
            XCTAssertGreaterThan(motion.velocity * before.velocity, 0)
        }
    }
    func testSpringRepeatedRapidReversalsStayFiniteAndBounded() {
        var motion = IslandMotion()
        let intervals = [0.001, 1.0 / 144, 0.013, 1.0 / 60, 0.041]
        for index in 0..<1_000 {
            motion.advance(expanded: index % 2 == 0, elapsed: intervals[index % intervals.count], reduceMotion: false)
            XCTAssertTrue(motion.progress.isFinite)
            XCTAssertTrue(motion.velocity.isFinite)
            XCTAssertGreaterThanOrEqual(motion.progress, 0)
            XCTAssertLessThanOrEqual(motion.progress, 1)
        }
        motion.advance(expanded: false, elapsed: 2, reduceMotion: false)
        XCTAssertEqual(motion.progress, 0)
        XCTAssertEqual(motion.velocity, 0)
        XCTAssertTrue(motion.isSettled)
    }
    func testSpringLongGapsSettleWithoutDiscardingTimeOrOverflow() {
        for elapsed in [1.0, 30, 1_000, Double.greatestFiniteMagnitude] {
            var motion = IslandMotion()
            motion.advance(expanded: true, elapsed: elapsed, reduceMotion: false)
            XCTAssertEqual(motion.progress, 1)
            XCTAssertEqual(motion.velocity, 0)
            XCTAssertTrue(motion.isSettled)
            motion.advance(expanded: false, elapsed: elapsed, reduceMotion: false)
            XCTAssertEqual(motion.progress, 0)
            XCTAssertEqual(motion.velocity, 0)
            XCTAssertTrue(motion.isSettled)
        }
    }
    func testSpringInvalidElapsedTimeLeavesStateUntouched() {
        var motion = IslandMotion()
        motion.advance(expanded: true, elapsed: 0.1, reduceMotion: false)
        let before = motion
        for elapsed in [0.0, -0.1, Double.nan, Double.infinity, -Double.infinity] {
            motion.advance(expanded: false, elapsed: elapsed, reduceMotion: false)
            XCTAssertEqual(motion, before)
        }
    }
    func testSpringSettlesSymmetricallyAndStaysAtExactEndpoints() {
        for initiallyExpanded in [false, true] {
            var motion = IslandMotion()
            motion.advance(expanded: initiallyExpanded, elapsed: 0, reduceMotion: true)
            let target = !initiallyExpanded
            var before = motion
            for _ in 0..<60 {
                before = motion
                motion.advance(expanded: target, elapsed: 1.0 / 60, reduceMotion: false)
                if motion.isSettled { break }
            }
            XCTAssertEqual(motion.progress, target ? 1 : 0)
            XCTAssertEqual(motion.velocity, 0)
            XCTAssertTrue(motion.isSettled)
            // The preceding tick is already within a sub-point normalized tail.
            XCTAssertLessThan(abs(motion.progress - before.progress), 0.002)
            let settled = motion
            for _ in 0..<10 {
                motion.advance(expanded: target, elapsed: 1.0 / 144, reduceMotion: false)
                XCTAssertEqual(motion, settled)
            }
        }
    }
    func testReduceMotionOverridesInvalidTimeAndCanResumeAnimation() {
        for elapsed in [0.0, -1, Double.nan, Double.infinity] {
            var motion = IslandMotion()
            motion.advance(expanded: true, elapsed: 0.1, reduceMotion: false)
            motion.advance(expanded: true, elapsed: elapsed, reduceMotion: true)
            XCTAssertEqual(motion.progress, 1)
            XCTAssertEqual(motion.velocity, 0)
            XCTAssertTrue(motion.isSettled)
            motion.advance(expanded: false, elapsed: 1.0 / 60, reduceMotion: false)
            XCTAssertGreaterThan(motion.progress, 0)
            XCTAssertLessThan(motion.progress, 1)
            XCTAssertLessThan(motion.velocity, 0)
            motion.advance(expanded: false, elapsed: elapsed, reduceMotion: true)
            XCTAssertEqual(motion.progress, 0)
            XCTAssertEqual(motion.velocity, 0)
            XCTAssertTrue(motion.isSettled)
        }
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
                    // Compact endpoint remains explicitly quantized at the same regression progress values.
                    XCTAssertEqual(island.frame(progress: 0.65), CGRect(x: 341, y: 612, width: 342, height: 156))
                    XCTAssertEqual(island.frame(progress: 0.8), CGRect(x: 341, y: 585, width: 342, height: 183))
                }
            }
        }
    }
    func testCollapsedContourEnvelopeWithOddWidthsAndFractionalOrigins() {
        for scale in [CGFloat(1), CGFloat(2)] {
            for width in [CGFloat(219), CGFloat(220.5), CGFloat(221)] {
                for x in [CGFloat(401.25), CGFloat(-913.5)] {
                    let screen = CGRect(x: x - 400, y: -200, width: 1024, height: 968)
                    let camera = CGRect(x: x, y: screen.maxY - 32.25, width: width, height: 32.25)
                    let notch = NotchGeometry(notch: camera, leftPanel: .zero, rightPanel: .zero)
                    let geometry = IslandGeometry(notch: notch, screen: screen, backingScale: scale)
                    let frame = geometry.frame(progress: 0)
                    let contour = geometry.contourFrame
                    let local = geometry.contourRect(progress: 0)
                    XCTAssertEqual(frame.size, geometry.collapsedSize)
                    XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.0001)
                    XCTAssertEqual(contour, CGRect(x: camera.minX - 3, y: camera.minY - 3,
                        width: camera.width + 6, height: camera.height + 3))
                    XCTAssertEqual(contour.midX, camera.midX)
                    XCTAssertEqual(contour.maxY, camera.maxY)
                    XCTAssertEqual(frame.minX + local.midX, camera.midX)
                    XCTAssertEqual(local.minY, 0)
                    XCTAssertEqual(local.size, contour.size)
                    for extensionSize in [camera.minX - frame.minX, frame.maxX - camera.maxX, camera.minY - frame.minY] {
                        XCTAssertGreaterThanOrEqual(extensionSize, 3)
                        XCTAssertLessThanOrEqual(extensionSize, 4.5) // Transparent native rounding; actual paint is gated at 4 pt.
                    }
                    for edge in [frame.minX, frame.maxX, frame.minY] {
                        XCTAssertEqual(edge * scale, (edge * scale).rounded(), accuracy: 0.0001)
                    }
                }
            }
        }
    }
    func testHorizontalCalibrationDefaultsRejectsNonfiniteAndUsesBoundedHalfPoints() {
        XCTAssertEqual(HorizontalCalibration.sanitized(), 0)
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(HorizontalCalibration.sanitized(value), 0)
        }
        for pair in [(0.0, 0.0), (0.24, 0), (-0.24, 0), (0.25, 0.5), (-0.25, -0.5),
                     (1.26, 1.5), (-1.26, -1.5), (99, 8), (-99, -8),
                     (Double.greatestFiniteMagnitude, 8), (-Double.greatestFiniteMagnitude, -8)] {
            XCTAssertEqual(HorizontalCalibration.sanitized(pair.0), pair.1)
        }
    }
    func testCalibrationKeepsRawHardwareAndResetsWithoutResidualOffset() throws {
        let screen = CGRect(x: -1024, y: 768, width: 1024, height: 768)
        let notch = try makeNotch(screen: screen, center: screen.midX + 61.25, width: 220.5)
        let baseline = IslandGeometry(notch: notch, screen: screen, backingScale: 2)
        for value in [-99.0, -8, -1.26, 0, 1.26, 8, 99, .nan, .infinity, -.infinity] {
            let geometry = IslandGeometry(notch: notch, screen: screen, backingScale: 2, horizontalAdjustment: value)
            let expected = HorizontalCalibration.sanitized(value)
            XCTAssertEqual(geometry.horizontalAdjustment, expected)
            XCTAssertEqual(geometry.notch, notch.notch)
            XCTAssertEqual(geometry.calibratedNotch, notch.notch.offsetBy(dx: expected, dy: 0))
            XCTAssertEqual(geometry.contourFrame.midX - baseline.contourFrame.midX, expected)
            let reset = IslandGeometry(notch: notch, screen: screen, backingScale: 2, horizontalAdjustment: 0)
            XCTAssertEqual(reset, baseline)
        }
    }
    func testExactCalibratedAnchorThroughFramesRailHoverAndClick() throws {
        for scale in [CGFloat(1), CGFloat(2)] {
            for origin in [CGPoint.zero, CGPoint(x: -1512, y: -982)] {
                let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
                for width in [CGFloat(219), 220, 220.5, 221] {
                    for offCenter in [CGFloat(-61.25), 0, 61.25] {
                        let notch = try makeNotch(screen: screen, center: screen.midX + offCenter, width: width)
                        for adjustment in [-8.0, -1.5, 0, 2.5, 8] {
                            let geometry = IslandGeometry(notch: notch, screen: screen,
                                backingScale: scale, horizontalAdjustment: adjustment)
                            let anchor = notch.notch.midX + adjustment
                            XCTAssertEqual(geometry.calibratedNotch.midX, anchor)
                            for step in 0...20 {
                                let progress = Double(step) / 20
                                let native = geometry.frame(progress: progress)
                                let contour = geometry.contourRect(progress: progress)
                                let rail = geometry.railRect(progress: progress)
                                let global = globalRect(contour, in: native)
                                XCTAssertEqual(global.midX, anchor, accuracy: 0.0001)
                                XCTAssertEqual(global.maxY, screen.maxY, accuracy: 0.0001)
                                XCTAssertEqual(globalRect(rail, in: native), geometry.contourFrame)
                                XCTAssertEqual(rail.size, geometry.contourFrame.size)
                                XCTAssertTrue(screen.contains(native))
                                XCTAssertTrue(native.insetBy(dx: -0.0001, dy: -0.0001).contains(global))
                                XCTAssertEqual(contour.minY, 0, accuracy: 0.0001)
                                for edge in [native.minX, native.maxX, native.minY] {
                                    XCTAssertEqual(edge * scale, (edge * scale).rounded(), accuracy: 0.0001)
                                }
                                XCTAssertTrue(geometry.hoverContains(CGPoint(x: global.minX + 12 * progress + 0.01, y: global.midY), progress: progress))
                                XCTAssertFalse(geometry.hoverContains(CGPoint(x: global.minX + 12 * progress - 0.01, y: global.midY), progress: progress))
                                XCTAssertTrue(geometry.hoverContains(CGPoint(x: global.maxX - 12 * progress - 0.01, y: global.midY), progress: progress))
                                XCTAssertFalse(geometry.hoverContains(CGPoint(x: global.maxX - 12 * progress + 0.01, y: global.midY), progress: progress))
                            }
                            let expanded = globalRect(geometry.contourRect(progress: 1), in: geometry.frame(progress: 1))
                            XCTAssertEqual(expanded.midX, anchor)
                            XCTAssertTrue(geometry.interactiveContains(CGPoint(x: expanded.minX + 16.01, y: expanded.midY)))
                            XCTAssertFalse(geometry.interactiveContains(CGPoint(x: expanded.minX + 15.99, y: expanded.midY)))
                            XCTAssertTrue(geometry.interactiveContains(CGPoint(x: expanded.maxX - 16.01, y: expanded.midY)))
                            XCTAssertFalse(geometry.interactiveContains(CGPoint(x: expanded.maxX - 15.99, y: expanded.midY)))
                            XCTAssertFalse(geometry.interactiveContains(CGPoint(x: anchor, y: screen.maxY - 4)))
                        }
                    }
                }
            }
        }
    }
    func testContourOriginCancelsNativeEnvelopeMidpointBias() {
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let camera = CGRect(x: 401.25, y: 735.75, width: 219, height: 32.25)
        let notch = NotchGeometry(notch: camera, leftPanel: .zero, rightPanel: .zero)
        let geometry = IslandGeometry(notch: notch, screen: screen, backingScale: 1)
        let native = geometry.frame(progress: 0)
        XCTAssertEqual(native.midX - camera.midX, -0.25)
        XCTAssertEqual(geometry.contourRect(progress: 0).minX, 1.25)
        XCTAssertEqual(native.minX + geometry.contourRect(progress: 0).midX, camera.midX)
    }
    func testCalibrationClampsAtScreenMarginWithoutChangingAnchorAtZero() throws {
        for scale in [CGFloat(1), CGFloat(2)] {
            let screen = CGRect(x: -1024, y: 768, width: 1024, height: 768)
            for leftSide in [true, false] {
                let center = leftSide ? screen.minX + 184.25 : screen.maxX - 184.25
                let notch = try makeNotch(screen: screen, center: center, width: 220.5)
                let geometry = IslandGeometry(notch: notch, screen: screen, backingScale: scale,
                    horizontalAdjustment: leftSide ? -8 : 8)
                XCTAssertEqual(geometry.horizontalAdjustment, leftSide ? -2 : 2)
                XCTAssertEqual(geometry.notch, notch.notch)
                for step in 0...20 {
                    let progress = Double(step) / 20
                    let native = geometry.frame(progress: progress)
                    XCTAssertTrue(screen.contains(native))
                    XCTAssertEqual(globalRect(geometry.contourRect(progress: progress), in: native).midX,
                        center + geometry.horizontalAdjustment, accuracy: 0.0001)
                }
                let expanded = geometry.frame(progress: 1)
                XCTAssertGreaterThanOrEqual(expanded.minX, screen.minX + 12)
                XCTAssertLessThanOrEqual(expanded.maxX, screen.maxX - 12)
                let reset = IslandGeometry(notch: notch, screen: screen, backingScale: scale)
                XCTAssertEqual(reset.horizontalAdjustment, 0)
                XCTAssertEqual(reset.contourFrame.midX, center)
            }
        }
    }
    func testNearEdgeExceptionKeepsFullCardAndRawCollapsedAnchor() throws {
        let screen = CGRect(x: -1024, y: -768, width: 1024, height: 768)
        for leftSide in [true, false] {
            let center = leftSide ? screen.minX + 116.25 : screen.maxX - 116.25
            let notch = try makeNotch(screen: screen, center: center, width: 220)
            let geometry = IslandGeometry(notch: notch, screen: screen, backingScale: 2,
                horizontalAdjustment: leftSide ? -8 : 8)
            // The bounded curved top envelope leaves 2.75pt before half-point quantization.
            XCTAssertEqual(geometry.horizontalAdjustment, leftSide ? -2.5 : 2.5)
            XCTAssertEqual(geometry.notch, notch.notch)
            XCTAssertEqual(geometry.contourFrame.midX, center + geometry.horizontalAdjustment)
            let expanded = globalRect(geometry.contourRect(progress: 1), in: geometry.frame(progress: 1))
            XCTAssertEqual(expanded.width, 340)
            XCTAssertNotEqual(expanded.midX, geometry.calibratedNotch.midX)
            XCTAssertEqual(leftSide ? expanded.minX : expanded.maxX,
                leftSide ? screen.minX + 12 : screen.maxX - 12)
            for step in 0...20 {
                let progress = Double(step) / 20
                XCTAssertTrue(screen.contains(geometry.frame(progress: progress)))
                XCTAssertEqual(globalRect(geometry.railRect(progress: progress), in: geometry.frame(progress: progress)), geometry.contourFrame)
            }
            XCTAssertTrue(geometry.interactiveContains(CGPoint(x: expanded.midX, y: expanded.midY)))
        }
    }
    func testInvalidProgressAndBackingScaleUseDefaultGeometry() throws {
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let notch = try makeNotch(screen: screen, center: screen.midX + 0.25, width: 221)
        let baseline = IslandGeometry(notch: notch, screen: screen)
        for scale in [CGFloat(0), -1, .nan, .infinity] {
            let geometry = IslandGeometry(notch: notch, screen: screen, backingScale: scale)
            XCTAssertEqual(geometry, baseline)
        }
        for progress in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(baseline.frame(progress: progress), baseline.frame(progress: 0))
            XCTAssertEqual(baseline.contourRect(progress: progress), baseline.contourRect(progress: 0))
        }
        XCTAssertEqual(baseline.frame(progress: 2), baseline.frame(progress: 1))
    }
    private func makeNotch(screen: CGRect, center: CGFloat, width: CGFloat) throws -> NotchGeometry {
        let leftEdge = center - width / 2
        let rightEdge = center + width / 2
        return try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32.25,
            auxiliaryLeft: CGRect(x: screen.minX, y: screen.maxY - 32.25,
                width: leftEdge - screen.minX, height: 32.25),
            auxiliaryRight: CGRect(x: rightEdge, y: screen.maxY - 32.25,
                width: screen.maxX - rightEdge, height: 32.25)))
    }
    private func globalRect(_ local: CGRect, in native: CGRect) -> CGRect {
        CGRect(x: native.minX + local.minX, y: native.maxY - local.maxY,
            width: local.width, height: local.height)
    }
}
