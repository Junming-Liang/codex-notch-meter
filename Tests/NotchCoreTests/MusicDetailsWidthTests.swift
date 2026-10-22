import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

/// These exercise the opt-in details excursion, not a replacement for the shared
/// music/notice map. Existing exact shared/ordinary-map tests remain unchanged.
/// Affine straight sides/top bounds do not imply that every fixed-y cross-section
/// is monotone: the existing circular corner morph is deliberately unchanged.
final class MusicDetailsWidthTests: XCTestCase {
    private struct Edges {
        let rawWidth: Double
        let center: Double
        let span: Double
        let left: Double
        let right: Double
        let topLeft: Double
        let topRight: Double
        let height: Double
        var affineValues: [Double] { [rawWidth, center, span, left, right, topLeft, topRight, height] }
    }
    private func geometry(width: CGFloat = 220, depth: CGFloat = 32, content: CGFloat = 260,
                          scale: CGFloat = 2, calibration: ContourCalibration = .init(),
                          cameraLeft: CGFloat? = nil) -> IslandGeometry {
        let screen = CGRect(x: -2048.25, y: -120, width: 1440, height: 900)
        let left = cameraLeft.map { screen.minX + $0 } ?? (screen.midX + 13.25 - width / 2)
        let raw = CGRect(x: left, y: screen.maxY - depth, width: width, height: depth)
        var value = IslandGeometry(notch: NotchGeometry(notch: raw, leftPanel: .zero, rightPanel: .zero),
            screen: screen, backingScale: scale, shapeCalibration: calibration, contentHeight: content)
        value.showsMusicAccessories = value.canShowMusicAccessories
        value.musicAccessoryProgress = 1
        return value
    }
    private func edges(_ g: IslandGeometry, _ p: Double) -> Edges {
        let native = g.frame(progress: p), local = g.contourRect(progress: p)
        let rect = CGRect(x: native.minX + local.minX, y: 0, width: local.width, height: local.height)
        let contour = IslandContour(rect: rect, progress: p,
            cornerAdjustment: g.shapeCalibration.corner, referenceDepth: g.notch.height)
        return Edges(rawWidth: Double(rect.width), center: Double(rect.midX),
            span: Double(rect.width - 2 * contour.shoulder), left: Double(rect.minX + contour.shoulder),
            right: Double(rect.maxX - contour.shoulder), topLeft: Double(contour.bounds.minX),
            topRight: Double(contour.bounds.maxX), height: Double(rect.height))
    }
    private func verifyAffine(_ canonical: IslandGeometry, rest: Double,
                              file: StaticString = #filePath, line: UInt = #line) {
        var direct = canonical; direct.detailsWidthRestProgress = rest
        let start = edges(canonical, rest).affineValues, end = edges(canonical, 1).affineValues
        let context = "width=\(canonical.notch.width) depth=\(canonical.notch.height) cal=\(canonical.shapeCalibration) a=\(canonical.musicAccessoryProgress) r=\(rest)"
        XCTAssertEqual(direct.frame(progress: rest), canonical.frame(progress: rest), context, file: file, line: line)
        XCTAssertEqual(direct.frame(progress: 1), canonical.frame(progress: 1), context, file: file, line: line)
        for step in 0...32 {
            let t = Double(step) / 32, p = rest + (1 - rest) * t
            let actual = edges(direct, p).affineValues
            for index in actual.indices {
                XCTAssertEqual(actual[index], start[index] + (end[index] - start[index]) * t,
                    accuracy: 1e-7, "\(context) metric=\(index) p=\(p)", file: file, line: line)
                XCTAssertGreaterThanOrEqual(actual[index] + 1e-7, min(start[index], end[index]), context, file: file, line: line)
                XCTAssertLessThanOrEqual(actual[index] - 1e-7, max(start[index], end[index]), context, file: file, line: line)
            }
            let frame = direct.frame(progress: p), scale = direct.backingScale
            // A fractional screen origin may require a subpixel transparent
            // envelope outside that origin. Compare to the outward pixel grid,
            // while the actual painted top bounds stay inside the exact screen.
            let pixelLeft = floor(direct.screen.minX * scale) / scale
            let pixelRight = ceil(direct.screen.maxX * scale) / scale
            XCTAssertGreaterThanOrEqual(frame.minX + 1e-7, pixelLeft, context, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX - 1e-7, pixelRight, context, file: file, line: line)
            XCTAssertGreaterThanOrEqual(actual[5] + 1e-7, Double(direct.screen.minX), context, file: file, line: line)
            XCTAssertLessThanOrEqual(actual[6] - 1e-7, Double(direct.screen.maxX), context, file: file, line: line)
        }
    }
    func testFixedAccessoryMatrixMovesRealSidesAndTopEnvelopeTowardTheirEndpoints() {
        let calibrations = [ContourCalibration(), .init(width: -16, depth: -3, corner: -6),
                            .init(width: 16, depth: 6, corner: 6)]
        for width in [CGFloat(220), 300, 330, 350, 360] {
            for content in [CGFloat(132), 180, 260, 340] {
                for scale in [CGFloat(1), 2] {
                    for calibration in calibrations {
                        for accessory in [0.0, 0.2, 0.5, 0.8, 1] {
                            var g = geometry(width: width, content: content, scale: scale, calibration: calibration)
                            g.musicAccessoryProgress = accessory
                            for rest in [0, g.musicProgress(contentHeight: 48), g.musicProgress(contentHeight: 68), g.musicProgress(contentHeight: 90)] {
                                verifyAffine(g, rest: rest)
                            }
                        }
                    }
                }
            }
        }
    }
    func testShiftedCentersDepthAndIneligibleAccessoriesRetainAffineVisibleEdges() {
        for depth in [CGFloat(20), 32, 40] {
            for left in [CGFloat(5), 40, 1180, 1215] {
                for calibration in [ContourCalibration(), .init(width: 16, depth: -6, corner: 6)] {
                    var g = geometry(depth: depth, calibration: calibration, cameraLeft: left)
                    for accessory in [0.0, 0.5, 1] {
                        g.musicAccessoryProgress = accessory
                        for rest in [0, g.musicProgress(contentHeight: 48), g.musicProgress(contentHeight: 90)] {
                            verifyAffine(g, rest: rest)
                        }
                    }
                }
            }
        }
    }
    func testRealSpringOldSideDipIsRejectedAt60And120HzWithoutChangingSharedMap() {
        let canonical = geometry()
        var direct = canonical; direct.detailsWidthRestProgress = 0
        for hz in [60.0, 120.0] {
            var motion = IslandMotion()
            var priorOld = edges(canonical, 0).span, priorNew = edges(direct, 0).span
            var oldMidpathDrops = 0
            for step in 1...Int(hz) {
                motion.advance(target: 1, elapsed: 1 / hz, reduceMotion: false)
                let old = edges(canonical, motion.progress), new = edges(direct, motion.progress)
                let time = Double(step) / hz
                if time >= 0.04 && time <= 0.13 && old.span < priorOld - 1e-9 { oldMidpathDrops += 1 }
                XCTAssertGreaterThanOrEqual(new.span + 1e-9, priorNew)
                XCTAssertEqual(new.span, 288 + 88 * motion.progress, accuracy: 1e-8)
                priorOld = old.span; priorNew = new.span
            }
            // Expected-old-red control: this proves the existing shared route
            // has the defect; it is not an intentionally failing test.
            XCTAssertEqual(oldMidpathDrops, hz == 60 ? 1 : 4)
            XCTAssertTrue(motion.isSettled(at: 1))
            for _ in 0..<Int(hz) {
                motion.advance(target: 0, elapsed: 1 / hz, reduceMotion: false)
                let current = edges(direct, motion.progress).span
                XCTAssertLessThanOrEqual(current - 1e-9, priorNew)
                priorNew = current
            }
            XCTAssertTrue(motion.isSettled(at: 0))
        }
    }
    func testInterruptedReversalsPreserveSpringAndWidthVelocityAndRetraceSamePath() {
        for width in [CGFloat(220), 330, 360] {
            for hz in [60.0, 120.0] {
                let canonical = geometry(width: width)
                for rest in [0, canonical.musicProgress(contentHeight: 68)] {
                    var direct = canonical; direct.detailsWidthRestProgress = rest
                    var motion = IslandMotion()
                    motion.advance(target: rest, elapsed: 0, reduceMotion: true)
                    let a = edges(canonical, rest), b = edges(canonical, 1)
                    for (target, count) in [(1.0, 5), (rest, 4), (1.0, 8), (rest, Int(hz)), (1.0, Int(hz))] {
                        let beforeMotion = motion
                        let beforeWidth = direct.widthSample(progress: motion.progress, velocity: motion.velocity)
                        motion.advance(target: target, elapsed: 0, reduceMotion: false)
                        XCTAssertEqual(motion, beforeMotion)
                        XCTAssertEqual(direct.widthSample(progress: motion.progress, velocity: motion.velocity), beforeWidth)
                        for _ in 0..<count {
                            let previous = motion
                            motion.advance(target: target, elapsed: 1 / hz, reduceMotion: false)
                            let t = (motion.progress - rest) / (1 - rest)
                            XCTAssertEqual(edges(direct, motion.progress).span, a.span + (b.span - a.span) * t, accuracy: 1e-8)
                            let expectedChange = (b.span - a.span) * (motion.progress - previous.progress) / (1 - rest)
                            XCTAssertEqual(edges(direct, motion.progress).span - edges(direct, previous.progress).span,
                                expectedChange, accuracy: 1e-8)
                        }
                    }
                }
            }
        }
    }
    func testDynamicAccessoryDerivativeMatchesFiniteDifference() {
        for left in [CGFloat(40), 610] {
            var canonical = geometry(cameraLeft: left)
            canonical.musicAccessoryProgress = 0.37
            for rest in [0, canonical.musicProgress(contentHeight: 48), canonical.musicProgress(contentHeight: 68), canonical.musicProgress(contentHeight: 90)] {
                var direct = canonical; direct.detailsWidthRestProgress = rest
                for fraction in [0.1, 0.4, 0.8] {
                    let p = rest + (1 - rest) * fraction
                    for velocity in [-0.7, 0.7] {
                        for accessoryVelocity in [-0.5, 0.8] {
                            let dt = 1e-7
                            let sample = direct.widthSample(progress: p, velocity: velocity, accessoryVelocity: accessoryVelocity)
                            var ahead = direct, behind = direct
                            ahead.musicAccessoryProgress += accessoryVelocity * dt
                            behind.musicAccessoryProgress -= accessoryVelocity * dt
                            let high = ahead.widthSample(progress: p + velocity * dt)
                            let low = behind.widthSample(progress: p - velocity * dt)
                            XCTAssertEqual(sample.widthVelocity, (high.width - low.width) / (2 * dt), accuracy: 1e-5)
                            XCTAssertEqual(sample.centerVelocity, (high.center - low.center) / (2 * dt), accuracy: 1e-5)
                        }
                    }
                }
            }
        }
    }
    func testEnablingAtSettledRestPreservesMovingAccessoryVelocity() {
        var accessory = IslandMotion()
        accessory.advance(target: 1, elapsed: 0.05, reduceMotion: false)
        XCTAssertGreaterThan(accessory.velocity, 0)
        var canonical = geometry(cameraLeft: 40)
        canonical.musicAccessoryProgress = accessory.progress
        for rest in [0, canonical.musicProgress(contentHeight: 48), canonical.musicProgress(contentHeight: 90)] {
            var direct = canonical; direct.detailsWidthRestProgress = rest
            let old = canonical.widthSample(progress: rest, velocity: 0, accessoryVelocity: accessory.velocity)
            let new = direct.widthSample(progress: rest, velocity: 0, accessoryVelocity: accessory.velocity)
            XCTAssertEqual(old, new)
            var motion = IslandMotion(), nextAccessory = accessory
            motion.advance(target: rest, elapsed: 0, reduceMotion: true)
            let dt = 1e-7
            motion.advance(target: 1, elapsed: dt, reduceMotion: false)
            nextAccessory.advance(target: 1, elapsed: dt, reduceMotion: false)
            direct.musicAccessoryProgress = nextAccessory.progress
            let after = direct.widthSample(progress: motion.progress)
            XCTAssertEqual((after.width - new.width) / dt, new.widthVelocity, accuracy: 0.01)
            XCTAssertEqual((after.center - new.center) / dt, new.centerVelocity, accuracy: 0.01)
        }
    }
    func testFullEndpointCanRelatchNewRestWithoutWaitingForAccessories() {
        var canonical = geometry(); canonical.musicAccessoryProgress = 0.3
        for oldRest in [0, canonical.musicProgress(contentHeight: 48)] {
            var old = canonical; old.detailsWidthRestProgress = oldRest
            for newRest in [0, canonical.musicProgress(contentHeight: 90)] {
                var new = canonical; new.detailsWidthRestProgress = newRest
                XCTAssertEqual(old.widthSample(progress: 1, velocity: 0, accessoryVelocity: 4),
                    new.widthSample(progress: 1, velocity: 0, accessoryVelocity: 4))
                XCTAssertEqual(old.frame(progress: 1), new.frame(progress: 1))
            }
        }
    }
    func testCanonicalGestureAndClickGeometryStayUnchanged() {
        let canonical = geometry(width: 330)
        var direct = canonical; direct.detailsWidthRestProgress = canonical.musicProgress(contentHeight: 68)
        XCTAssertEqual(direct.musicGestureCorridor, canonical.musicGestureCorridor)
        XCTAssertEqual(direct.expandedContentCenterX, canonical.expandedContentCenterX)
        for x in stride(from: -220.0, through: 220, by: 10) {
            for y in [0.0, 8, 16, 34, 36, 50, 100, 180, 300] {
                let point = CGPoint(x: canonical.notch.midX + CGFloat(x), y: canonical.screen.maxY - CGFloat(y))
                XCTAssertEqual(direct.interactiveContains(point), canonical.interactiveContains(point))
                for p in [0.0, 0.1, 0.3, 0.6, 1] {
                    XCTAssertEqual(direct.canonicalHoverContains(point, progress: p), canonical.canonicalHoverContains(point, progress: p))
                }
            }
        }
    }
    func testRetainedMusicOriginUsesTrueClosedShellNotSelectedRestProfile() {
        var wide = geometry(width: 330)
        wide.detailsWidthRestProgress = wide.musicProgress(contentHeight: 48)
        let wing = CGPoint(x: wide.notch.midX + 194, y: wide.screen.maxY - 16)
        XCTAssertFalse(wide.hoverContains(wing, progress: 1))
        XCTAssertTrue(wide.hoverContains(wing, progress: 1, retainingMusicOrigin: true))
        var narrow = geometry()
        let rest = narrow.musicProgress(contentHeight: 48)
        narrow.detailsWidthRestProgress = rest
        let invisibleClosedPoint = CGPoint(x: narrow.notch.midX + 179, y: narrow.screen.maxY - 16)
        XCTAssertFalse(narrow.hoverContains(invisibleClosedPoint, progress: rest))
        XCTAssertFalse(narrow.hoverContains(invisibleClosedPoint, progress: rest, retainingMusicOrigin: true))
    }
    func testSelectedRestProfileFallsBackBelowItsDomainAndKeepsCanonicalIdleReference() {
        var canonical = geometry(width: 180, content: 132)
        canonical.musicAccessoryProgress = 0
        for rest in [canonical.musicProgress(contentHeight: 48), canonical.musicProgress(contentHeight: 68),
                     canonical.musicProgress(contentHeight: 90)] {
            var direct = canonical; direct.detailsWidthRestProgress = rest
            XCTAssertEqual(direct.collapsedSize, canonical.collapsedSize)
            for p in [0, rest / 2, rest.nextDown] {
                XCTAssertEqual(direct.widthSample(progress: p, velocity: 0.4, accessoryVelocity: 0.6),
                    canonical.widthSample(progress: p, velocity: 0.4, accessoryVelocity: 0.6))
                XCTAssertEqual(direct.frame(progress: p), canonical.frame(progress: p))
                XCTAssertEqual(direct.contourRect(progress: p), canonical.contourRect(progress: p))
                XCTAssertEqual(direct.contourResidual(progress: p), canonical.contourResidual(progress: p), accuracy: 1e-9)
            }
            // At the selected rest both current shapes are identical, but the
            // residual must reference the true p=0 shell, not the compact width.
            XCTAssertEqual(direct.contourResidual(progress: rest), canonical.contourResidual(progress: rest), accuracy: 1e-9)
        }
        let lower = canonical.musicProgress(contentHeight: 48)
        let heightOnly = canonical.contourRect(progress: lower).height - canonical.contourRect(progress: 0).height
        // Make the reference-width assertion non-vacuous: height is not the
        // largest residual for this narrow shell and cannot hide a wrong origin.
        XCTAssertGreaterThan(canonical.contourResidual(progress: lower), Double(heightOnly) + 5)
    }
    func testPublishedWidthOverrideStillWinsAndInvalidRestFallsBackToSharedMap() {
        let canonical = geometry()
        var direct = canonical; direct.detailsWidthRestProgress = 0
        let override = IslandWidthSample(width: 385, center: Double(canonical.notch.midX) + 2, widthVelocity: -20)
        direct.widthPresentation = IslandWidthPresentation(progress: 0.3, sample: override)
        XCTAssertEqual(direct.widthSample(progress: 0.3), override)
        XCTAssertEqual(Double(direct.contourRect(progress: 0.3).width), override.width)
        for invalid in [-1.0, 1, .infinity, .nan] {
            var value = canonical; value.detailsWidthRestProgress = invalid
            for p in [0.0, 0.1, 0.5, 1] {
                XCTAssertEqual(value.widthSample(progress: p), canonical.widthSample(progress: p))
                XCTAssertEqual(value.contourRect(progress: p), canonical.contourRect(progress: p))
            }
        }
    }
}
