import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class IslandWidthMotionTests: XCTestCase {
    private func geometry(contentHeight: CGFloat = 260, scale: CGFloat = 2) -> IslandGeometry {
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let raw = CGRect(x: 402, y: 736, width: 220, height: 32)
        return IslandGeometry(notch: NotchGeometry(notch: raw, leftPanel: .zero, rightPanel: .zero),
            screen: screen, backingScale: scale, contentHeight: contentHeight)
    }
    private func smooth(_ x: Double) -> Double { let q = min(1, max(0, x)); return q * q * (3 - 2 * q) }
    private func bridge(_ from: IslandWidthSample, to width: Double, center: Double = 512) -> IslandWidthBridge {
        IslandWidthBridge(from: from, to: IslandWidthSample(width: width, center: center),
            widthBounds: 226...400, centerBounds: 500...524)
    }
    func testDefaultSharedMapRemainsExactAcrossAccessoriesAndHeights() {
        for height in [CGFloat(132), 180, 260, 340] {
            for accessory in [0.0, 0.2, 0.7, 1] {
                var g = geometry(contentHeight: height)
                g.showsMusicAccessories = true; g.musicAccessoryProgress = accessory
                XCTAssertFalse(g.ordinaryHoverWidth)
                for i in 0...100 {
                    let p = Double(i) / 100
                    let closed = 226 + 62 * accessory
                    let expected = closed + (360 - closed) * smooth(p / g.musicProgress(contentHeight: 48))
                        + 40 * smooth((p - g.musicProgress(contentHeight: 90)) / (1 - g.musicProgress(contentHeight: 90)))
                    XCTAssertEqual(Double(g.contourRect(progress: p).width), expected, accuracy: 1e-10)
                    XCTAssertEqual(g.widthSample(progress: p).width, expected, accuracy: 1e-10)
                }
            }
        }
    }
    func testOrdinaryMapRetainsDimensionsAndHeightButHasNoIntermediatePlateau() {
        for height in [CGFloat(132), 180, 260, 340] {
            let shared = geometry(contentHeight: height)
            var ordinary = shared; ordinary.ordinaryHoverWidth = true
            XCTAssertEqual(ordinary.frame(progress: 0), shared.frame(progress: 0))
            XCTAssertEqual(ordinary.frame(progress: 1), shared.frame(progress: 1))
            var previous = ordinary.widthSample(progress: 0).width
            for i in 1...100 {
                let p = ordinary.updateProgress * Double(i) / 100
                let sample = ordinary.widthSample(progress: p, velocity: 1)
                XCTAssertGreaterThan(sample.width, previous)
                XCTAssertEqual(sample.width, 226 + 174 * smooth(p / ordinary.updateProgress), accuracy: 1e-10)
                XCTAssertEqual(ordinary.contourRect(progress: p).height, shared.contourRect(progress: p).height)
                XCTAssertEqual(ordinary.frame(progress: p).maxY, shared.frame(progress: p).maxY)
                previous = sample.width
            }
            XCTAssertEqual(ordinary.widthSample(progress: ordinary.updateProgress).width, 400)
            XCTAssertEqual(ordinary.widthSample(progress: 0, velocity: 1).widthVelocity, 0)
            XCTAssertEqual(ordinary.widthSample(progress: 1, velocity: 1).widthVelocity, 0)
        }
    }
    func testWidthVelocityMatchesFiniteDifferenceAwayFromJoins() {
        for ordinary in [false, true] {
            var g = geometry(); g.ordinaryHoverWidth = ordinary
            g.showsMusicAccessories = true; g.musicAccessoryProgress = 0.4
            for p in [0.05, 0.15, 0.45, 0.8] {
                let dt = 1e-7, velocity = -0.7, av = 0.3
                let expected = g.widthSample(progress: p, velocity: velocity, accessoryVelocity: av)
                var ahead = g, behind = g
                ahead.musicAccessoryProgress += av * dt; behind.musicAccessoryProgress -= av * dt
                let finite = (ahead.widthSample(progress: p + velocity * dt).width
                    - behind.widthSample(progress: p - velocity * dt).width) / (2 * dt)
                XCTAssertEqual(expected.widthVelocity, finite, accuracy: 1e-5)
            }
        }
    }
    func testOrdinaryOpeningPlaybackCannotReinterpretWidthBeforeFullEndpoint() {
        var g = geometry(); g.ordinaryHoverWidth = true
        for i in 0...100 {
            let p = Double(i) / 100, before = g.widthSample(progress: p)
            g.showsMusicAccessories = true; g.musicAccessoryProgress = Double(i) / 100
            XCTAssertEqual(g.widthSample(progress: p), before)
        }
        let ordinary = g.widthSample(progress: 1, velocity: 0.1, accessoryVelocity: 2)
        g.ordinaryHoverWidth = false
        XCTAssertEqual(g.widthSample(progress: 1, velocity: 0.1, accessoryVelocity: 2), ordinary)
    }
    func testInterruptedClosingBridgesKeepWidthBoundedAndMatchVelocity() {
        var g = geometry(); g.ordinaryHoverWidth = true
        for time in [0.02, 0.04, 0.06, 0.08, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5] {
            var motion = IslandMotion(); motion.advance(target: 1, elapsed: 0, reduceMotion: true)
            motion.advance(target: 0, elapsed: time, reduceMotion: false)
            let initial = g.widthSample(progress: motion.progress, velocity: motion.velocity)
            for target in [226.0, 288, 360, 400] { // pause, playing idle, compact owner, reentry
                var b = bridge(initial, to: target)
                XCTAssertEqual(b.sample.width, initial.width)
                XCTAssertEqual(b.sample.widthVelocity, initial.widthVelocity, accuracy: 1e-10)
                for _ in 0..<1000 {
                    b.advance(elapsed: 0.001)
                    XCTAssertGreaterThanOrEqual(b.sample.width, 226 - 1e-9)
                    XCTAssertLessThanOrEqual(b.sample.width, 400 + 1e-9)
                }
                XCTAssertTrue(b.isSettled)
                XCTAssertEqual(b.sample.width, target)
                XCTAssertEqual(b.sample.widthVelocity, 0)
            }
        }
    }
    func testRetargetDuringBrakeAndTravelKeepsC1ForNoticeMusicPauseAndReentry() {
        for slice in [0.001, 0.025, 0.08, 0.15] {
            var b = bridge(IslandWidthSample(width: 340, center: 512, widthVelocity: -700), to: 360)
            for target in [288.0, 226, 400, 360] {
                b.advance(elapsed: slice)
                let current = b.sample
                b = bridge(current, to: target)
                XCTAssertEqual(b.sample, current)
                let dt = 1e-7; b.advance(elapsed: dt)
                XCTAssertEqual((b.sample.width - current.width) / dt, current.widthVelocity, accuracy: 0.02)
            }
            b.advance(elapsed: 1)
            XCTAssertTrue(b.isSettled); XCTAssertEqual(b.sample.width, 360)
        }
    }
    func testNearEdgeCenterBridgeHasSameContinuityAndBounds() {
        var b = bridge(IslandWidthSample(width: 380, center: 516, widthVelocity: -300, centerVelocity: 20),
            to: 360, center: 500)
        XCTAssertEqual(b.sample.center, 516); XCTAssertEqual(b.sample.centerVelocity, 20)
        for _ in 0..<1000 {
            b.advance(elapsed: 0.001)
            XCTAssertGreaterThanOrEqual(b.sample.center, 500 - 1e-9)
            XCTAssertLessThanOrEqual(b.sample.center, 524 + 1e-9)
        }
        XCTAssertEqual(b.sample.center, 500); XCTAssertEqual(b.sample.centerVelocity, 0)
    }
    func testReducedMotionAndNonadvancingClock() {
        var b = bridge(IslandWidthSample(width: 380, center: 512, widthVelocity: -300), to: 288)
        let before = b
        for dt in [0.0, -1, .nan, .infinity] { b.advance(elapsed: dt); XCTAssertEqual(b, before) }
        b.advance(elapsed: 0, reduceMotion: true)
        XCTAssertTrue(b.isSettled); XCTAssertEqual(b.sample.width, 288); XCTAssertEqual(b.sample.widthVelocity, 0)
    }
    func testPresentationOverrideIsScopedAndCanonicalDetailCenterSurvives() {
        var g = geometry()
        let full = g.frame(progress: 1), center = g.expandedContentCenterX
        g.widthPresentation = IslandWidthPresentation(progress: 0.3,
            sample: IslandWidthSample(width: 385, center: 514, widthVelocity: -50))
        XCTAssertEqual(g.contourRect(progress: 0.3).width, 385)
        XCTAssertEqual(g.frame(progress: 1), full)
        XCTAssertEqual(g.expandedContentCenterX, center)
        g.widthPresentation = IslandWidthPresentation(progress: 1, sample: IslandWidthSample(width: 385, center: 514))
        XCTAssertEqual(g.expandedContentCenterX, center)
        XCTAssertEqual(g.contourRect(progress: 1).width, 385)
    }
    func testBridgeAtZeroProgressRetainsSurfaceUntilWidthActuallyCloses() {
        var g = geometry()
        g.widthPresentation = IslandWidthPresentation(progress: 0, sample: IslandWidthSample(width: 250, center: 512))
        XCTAssertGreaterThan(g.surfaceOpacity(progress: 0), 0)
        XCTAssertEqual(g.contourRect(progress: 0).height, 35)
        g.widthPresentation = nil
        XCTAssertEqual(g.surfaceOpacity(progress: 0), 0)
    }
    func testCoupledNearEdgeBridgeKeepsWholeContourInsideScreenAtBothScales() {
        for scale in [CGFloat(1), 2] {
            for origin in [CGFloat(0), -1024.25, 0.25] {
                for cameraX in [CGFloat(5), 799] {
                    let screen = CGRect(x: origin, y: -120, width: 1024, height: 768)
                    let raw = CGRect(x: origin + cameraX, y: screen.maxY - 32, width: 220, height: 32)
                    var g = IslandGeometry(notch: NotchGeometry(notch: raw, leftPanel: .zero, rightPanel: .zero),
                        screen: screen, backingScale: scale, contentHeight: 260)
                    g.ordinaryHoverWidth = true
                    for time in [0.04, 0.1, 0.18, 0.25, 0.4] {
                        var motion = IslandMotion(); motion.advance(target: 1, elapsed: 0, reduceMotion: true)
                        motion.advance(target: 0, elapsed: time, reduceMotion: false)
                        let from = g.widthSample(progress: motion.progress, velocity: motion.velocity)
                        var incoming = g; incoming.ordinaryHoverWidth = false
                        for p in [0.0, incoming.updateProgress, 1] {
                            let to = incoming.widthSample(progress: p)
                            let c0 = Double(g.calibratedNotch.midX), c1 = Double(g.expandedContentCenterX)
                            var b = IslandWidthBridge(from: from, to: to, widthBounds: 226...400,
                                centerBounds: min(c0, c1)...max(c0, c1), horizontalBounds: g.motionHorizontalBounds)
                            XCTAssertEqual(b.sample, from)
                            for _ in 0..<500 {
                                b.advance(elapsed: 0.001)
                                let sample = b.sample
                                XCTAssertGreaterThanOrEqual(sample.center - sample.width / 2,
                                    g.motionHorizontalBounds.lowerBound - 1e-9)
                                XCTAssertLessThanOrEqual(sample.center + sample.width / 2,
                                    g.motionHorizontalBounds.upperBound + 1e-9)
                                var painted = incoming
                                painted.widthPresentation = IslandWidthPresentation(progress: p, sample: sample)
                                let native = painted.frame(progress: p)
                                XCTAssertGreaterThanOrEqual(native.minX, screen.minX - 1e-9)
                                XCTAssertLessThanOrEqual(native.maxX, screen.maxX + 1e-9)
                                XCTAssertGreaterThanOrEqual(sample.width, 226 - 1e-9)
                                XCTAssertLessThanOrEqual(sample.width, 400 + 1e-9)
                            }
                            XCTAssertTrue(b.isSettled)
                        }
                    }
                }
            }
        }
    }

}
