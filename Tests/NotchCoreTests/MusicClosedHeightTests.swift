import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class MusicClosedHeightTests: XCTestCase {
    func testClosedMusicOnlyChangesWidthAcrossBackingScalesAndCalibrations() throws {
        for scale in [CGFloat(1), 2] {
            for origin in [CGPoint.zero, CGPoint(x: -1512, y: 945)] {
                for depth in [CGFloat(20), 32, 38] {
                    for adjustment in [-6.0, -3, 0, 6] {
                        for width in [-16.0, 0, 16] {
                            for horizontal in [-8.0, 0, 8] {
                                let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
                                let left = screen.midX - 110.25, right = left + 220.5
                                let notch = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: Double(depth),
                                    auxiliaryLeft: CGRect(x: screen.minX, y: screen.maxY - depth,
                                        width: left - screen.minX, height: depth),
                                    auxiliaryRight: CGRect(x: right, y: screen.maxY - depth,
                                        width: screen.maxX - right, height: depth)))
                                let normal = IslandGeometry(notch: notch, screen: screen, backingScale: scale,
                                    horizontalAdjustment: horizontal, shapeCalibration: .init(width: width, depth: adjustment))
                                for blend in [0.0, 0.25, 0.5, 0.75, 1] {
                                    var music = normal
                                    music.showsMusicAccessories = normal.canShowMusicAccessories
                                    music.musicAccessoryProgress = blend
                                    let a = normal.frame(progress: 0), b = music.frame(progress: 0)
                                    let ac = normal.contourRect(progress: 0), bc = music.contourRect(progress: 0)
                                    XCTAssertEqual(a.minY, b.minY)
                                    XCTAssertEqual(a.maxY, b.maxY)
                                    XCTAssertEqual(a.height, b.height)
                                    XCTAssertEqual(ac.height, bc.height)
                                    XCTAssertEqual(ac.maxY, bc.maxY)
                                    XCTAssertEqual(music.notch, normal.notch)
                                    XCTAssertEqual(music.calibratedNotch, normal.calibratedNotch)
                                    XCTAssertEqual(music.contourFrame, normal.contourFrame)
                                    if music.showsMusicAccessories && blend > 0 { XCTAssertGreaterThan(b.width, a.width) }
                                    else { XCTAssertEqual(a, b) }
                                    // Existing calibration semantics are retained, including
                                    // cases where the conservative raw mask covers the rail.
                                    let normalVisible = max(0, min(4, ac.maxY - depth))
                                    let musicVisible = max(0, min(4, bc.maxY - depth))
                                    XCTAssertEqual(normalVisible, musicVisible)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testDefaultBottomMaskCoverageIsIdenticalWithoutChangingStrokeOrHeight() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32,
            auxiliaryLeft: CGRect(x: 0, y: 868, width: 610, height: 32),
            auxiliaryRight: CGRect(x: 830, y: 868, width: 610, height: 32)))
        let normal = IslandGeometry(notch: notch, screen: screen)
        var music = normal; music.showsMusicAccessories = true
        for geometry in [normal, music] {
            let height = geometry.contourRect(progress: 0).height
            XCTAssertEqual(height, 35)
            let railCenter = height - 2
            XCTAssertEqual(railCenter - 1.75, 31.25)
            XCTAssertEqual(railCenter + 1.75 - max(32, railCenter - 1.75), 2.75)
            XCTAssertEqual(height - max(32, height - 4), 3)
        }
        // Width-only closure does not alter the approved compact lyric targets.
        for content in [CGFloat(48), 68, 90] {
            let p = normal.musicProgress(contentHeight: content)
            XCTAssertEqual(music.frame(progress: p), normal.frame(progress: p))
            XCTAssertEqual(music.contourRect(progress: p), normal.contourRect(progress: p))
        }
    }

    func testPlaybackStartPauseAndReconnectSpringsKeepEveryClosedBottomFixed() throws {
        let screen = CGRect(x: -1512, y: 945, width: 1440, height: 900)
        let left = screen.midX - 110.25, right = left + 220.5
        let notch = try XCTUnwrap(NotchGeometry.calculate(screen: screen, topInset: 32,
            auxiliaryLeft: CGRect(x: screen.minX, y: screen.maxY - 32,
                width: left - screen.minX, height: 32),
            auxiliaryRight: CGRect(x: right, y: screen.maxY - 32,
                width: screen.maxX - right, height: 32)))
        for scale in [CGFloat(1), 2] {
            for fps in [60.0, 120.0] {
                for calibration in [ContourCalibration(), .init(width: -16, depth: -3, corner: -6),
                                    .init(width: 16, depth: 6, corner: 6)] {
                    let normal = IslandGeometry(notch: notch, screen: screen, backingScale: scale,
                        horizontalAdjustment: 0.5, shapeCalibration: calibration)
                    let baseline = normal.frame(progress: 0)
                    var accessory = IslandMotion()
                    for playing in [true, false, true] {
                        var intermediate = 0
                        for _ in 0..<240 {
                            accessory.advance(expanded: playing, elapsed: 1 / fps, reduceMotion: false)
                            var music = normal
                            music.showsMusicAccessories = playing || accessory.progress > 0
                            music.musicAccessoryProgress = accessory.progress
                            let frame = music.frame(progress: 0)
                            XCTAssertEqual(frame.height, baseline.height)
                            XCTAssertEqual(frame.minY, baseline.minY)
                            XCTAssertEqual(frame.maxY, baseline.maxY)
                            XCTAssertEqual(music.notch, normal.notch)
                            XCTAssertEqual(music.contourRect(progress: 0).maxY, normal.contourRect(progress: 0).maxY)
                            if accessory.progress > 0 && accessory.progress < 1 { intermediate += 1 }
                            if accessory.isSettled(at: playing ? 1 : 0) { break }
                        }
                        XCTAssertGreaterThan(intermediate, 3)
                        XCTAssertTrue(accessory.isSettled(at: playing ? 1 : 0))
                    }
                }
            }
        }
    }
}
