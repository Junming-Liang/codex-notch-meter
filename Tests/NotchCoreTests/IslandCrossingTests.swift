import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class IslandCrossingTests: XCTestCase {
    private let corridor = CGRect(x: 100, y: 880, width: 280, height: 18)
    private func point(_ fraction: CGFloat, y: CGFloat = 889) -> CGPoint {
        CGPoint(x: corridor.minX + corridor.width * fraction, y: y)
    }
    private func traverse(_ detector: inout IslandCrossing, right: Bool, start: Double = 0) -> [IslandCrossing.Direction] {
        let positions: [CGFloat] = right ? [0.02, 0.25, 0.52, 0.75, 0.98] : [0.98, 0.75, 0.48, 0.25, 0.02]
        return positions.enumerated().compactMap { index, fraction in
            detector.update(point: point(fraction), now: start + Double(index) * 0.04, corridor: corridor, enabled: true)
        }
    }
    func testFullCrossingEachDirectionOnce() {
        for right in [true, false] {
            var detector = IslandCrossing()
            XCTAssertEqual(traverse(&detector, right: right), [right ? .right : .left])
            XCTAssertTrue(detector.isLocked)
            XCTAssertTrue(detector.reservesPointer)
            XCTAssertTrue(traverse(&detector, right: !right, start: 0.3).isEmpty)
        }
    }
    func testExitRearmsOppositeDirection() {
        var detector = IslandCrossing()
        XCTAssertEqual(traverse(&detector, right: true), [.right])
        XCTAssertNil(detector.update(point: point(1.1), now: 0.3, corridor: corridor, enabled: true))
        XCTAssertEqual(traverse(&detector, right: false, start: 0.4), [.left])
    }
    func testMiddleEntryAndStationaryHoverNeverCross() {
        var detector = IslandCrossing()
        for index in 0..<30 {
            XCTAssertNil(detector.update(point: point(0.5), now: Double(index) / 30, corridor: corridor, enabled: true))
        }
        XCTAssertFalse(detector.reservesPointer)
        XCTAssertTrue(traverse(&detector, right: true, start: 1.1).isEmpty)
    }
    func testShortJitterAndReversalRequireExit() {
        var detector = IslandCrossing()
        for (index, x) in [CGFloat(0.02), 0.2, 0.18, 0.5, 0.98].enumerated() {
            XCTAssertNil(detector.update(point: point(x), now: Double(index) * 0.04, corridor: corridor, enabled: true))
        }
    }
    func testVerticalDepartureResetsPartialCrossing() {
        var detector = IslandCrossing()
        XCTAssertNil(detector.update(point: point(0.02), now: 0, corridor: corridor, enabled: true))
        XCTAssertNil(detector.update(point: point(0.5, y: 850), now: 0.04, corridor: corridor, enabled: true))
        XCTAssertNil(detector.update(point: point(0.98), now: 0.08, corridor: corridor, enabled: true))
    }
    func testPermissionSuppressionOrButtonResetsPartialCrossing() {
        for buttons in [false, true] {
            var detector = IslandCrossing()
            XCTAssertNil(detector.update(point: point(0.02), now: 0, corridor: corridor, enabled: true))
            XCTAssertNil(detector.update(point: point(0.5), now: 0.04, corridor: corridor, enabled: buttons, buttonDown: buttons))
            XCTAssertNil(detector.update(point: point(0.98), now: 0.08, corridor: corridor, enabled: true))
        }
    }
    func testStalledAndReversedTimeFailClosed() {
        for next in [Double(-1), 0, 0.3, .infinity, .nan] {
            var detector = IslandCrossing()
            XCTAssertNil(detector.update(point: point(0.02), now: 0, corridor: corridor, enabled: true))
            XCTAssertNil(detector.update(point: point(0.5), now: next, corridor: corridor, enabled: true))
            XCTAssertNil(detector.update(point: point(0.98), now: 0.4, corridor: corridor, enabled: true))
        }
    }
    func testOverlongCrossingCannotAccumulateAcrossHover() {
        var detector = IslandCrossing()
        for index in 0...14 {
            let fraction = CGFloat(index) / 14 * 0.96 + 0.02
            XCTAssertNil(detector.update(point: point(fraction), now: Double(index) * 0.1, corridor: corridor, enabled: true))
        }
    }
    func testExplicitResetDiscardsHalfGesture() {
        var detector = IslandCrossing()
        XCTAssertNil(detector.update(point: point(0.02), now: 0, corridor: corridor, enabled: true))
        XCTAssertNil(detector.update(point: point(0.52), now: 0.04, corridor: corridor, enabled: true))
        detector.reset()
        XCTAssertNil(detector.update(point: point(0.98), now: 0.08, corridor: corridor, enabled: true))
    }
    func testPhysicalTopEdgeAndEndPointsAreInclusive() {
        var detector = IslandCrossing()
        for (index, fraction) in [CGFloat(0), 0.5, 1].enumerated() {
            let result = detector.update(point: point(fraction, y: corridor.maxY),
                now: Double(index) * 0.05, corridor: corridor, enabled: true)
            XCTAssertEqual(result, index == 2 ? .right : nil)
        }
    }
    func testInvalidSignedCorridorsCannotArm() {
        for invalid in [CGRect(x: 100, y: 880, width: -280, height: 18),
                        CGRect(x: CGFloat.nan, y: 880, width: 280, height: 18),
                        CGRect(x: 100, y: 880, width: 280, height: -18)] {
            var detector = IslandCrossing()
            XCTAssertNil(detector.update(point: point(0.02), now: 0, corridor: invalid, enabled: true))
            XCTAssertFalse(detector.isTracking)
        }
    }
    func testCameraGeometryAndRailStaySeparateFromMusicEnvelope() {
        for scale in [CGFloat(1), 2] {
            let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
            let raw = CGRect(x: 610, y: 868, width: 220, height: 32)
            let original = IslandGeometry(notch: NotchGeometry(notch: raw, leftPanel: .zero, rightPanel: .zero), screen: screen, backingScale: scale)
            var music = original; music.showsMusicAccessories = true
            XCTAssertEqual(music.notch, raw)
            XCTAssertEqual(music.calibratedNotch, original.calibratedNotch)
            XCTAssertEqual(music.contourFrame, original.contourFrame)
            XCTAssertEqual(music.frame(progress: 0).height, original.frame(progress: 0).height)
            XCTAssertGreaterThan(music.frame(progress: 0).width, original.frame(progress: 0).width)
            for p in [0.0, 0.02, 0.3, 0.7, 1.0] {
                let a = original.frame(progress: p), b = music.frame(progress: p)
                let ar = original.contourRect(progress: p), br = music.contourRect(progress: p)
                XCTAssertEqual(a.minX + ar.minX, b.minX + br.minX, accuracy: 1e-9)
                XCTAssertEqual(ar.size, br.size)
                XCTAssertEqual(music.musicGestureCorridor, original.musicGestureCorridor)
            }
        }
    }
}
