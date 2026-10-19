import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

/// Music may widen the presentation shell; it must never rewrite camera geometry.
/// These checks use global coordinates and independent interpolation/boundary probes.
final class MusicShellGeometryTests: XCTestCase {
    private let tolerance: CGFloat = 0.000001

    private func geometry(origin: CGPoint = .zero, scale: CGFloat = 2,
                          width: CGFloat = 220, depth: CGFloat = 32,
                          calibration: ContourCalibration = .init(),
                          horizontal: Double = 0, contentHeight: CGFloat = 180) -> IslandGeometry {
        let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
        let raw = CGRect(x: screen.midX - width / 2 + 13.25,
                         y: screen.maxY - depth, width: width, height: depth)
        return IslandGeometry(notch: NotchGeometry(notch: raw, leftPanel: .zero, rightPanel: .zero),
                              screen: screen, backingScale: scale, horizontalAdjustment: horizontal,
                              shapeCalibration: calibration, contentHeight: contentHeight)
    }

    private func global(_ rect: CGRect, geometry: IslandGeometry, progress: Double) -> CGRect {
        let native = geometry.frame(progress: progress)
        return CGRect(x: native.minX + rect.minX, y: native.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: tolerance, file: file, line: line)
    }

    func testClosedPlayingShellSurroundsAccessoriesWithoutChangingCameraCalibration() {
        for scale in [CGFloat(1), 2] {
            for origin in [CGPoint.zero, CGPoint(x: -2048, y: 900), CGPoint(x: 17, y: -1400)] {
                for calibration in [ContourCalibration(), .init(width: -16, depth: -3, corner: -6),
                                    .init(width: 16, depth: 6, corner: 6)] {
                    let idle = geometry(origin: origin, scale: scale, width: 219.5,
                                        calibration: calibration, horizontal: 0.5)
                    XCTAssertTrue(idle.canShowMusicAccessories)
                    var music = idle
                    music.showsMusicAccessories = true
                    XCTAssertEqual(music.notch, idle.notch)
                    XCTAssertEqual(music.calibratedNotch, idle.calibratedNotch)
                    XCTAssertEqual(music.contourFrame, idle.contourFrame)
                    XCTAssertEqual(music.musicGestureCorridor, idle.musicGestureCorridor)
                    XCTAssertTrue(music.hasSameAnchor(as: idle))
                    let rect = global(music.contourRect(progress: 0), geometry: music, progress: 0)
                    let expected = CGRect(x: idle.musicAccessoryFrame.minX, y: idle.contourFrame.minY,
                                          width: idle.musicAccessoryFrame.width, height: idle.contourFrame.height)
                    assertRect(rect, expected)
                    XCTAssertGreaterThan(rect.width, idle.contourFrame.width)
                    XCTAssertEqual(music.frame(progress: 0).height, idle.frame(progress: 0).height)
                    XCTAssertEqual(rect.midX, idle.calibratedNotch.midX, accuracy: tolerance)
                }
            }
        }
    }

    func testMusicWidthUsesOneContinuousMapAndConvergesAtMinimumLyricTarget() {
        for contentHeight in [CGFloat(132), 180, 340] {
            let idle = geometry(contentHeight: contentHeight)
            var music = idle
            music.showsMusicAccessories = true
            let lower = idle.musicProgress(contentHeight: 48)
            for p in [0.0, lower * 0.05, lower * 0.25, lower * 0.75, lower] {
                let t = CGFloat(p / lower)
                let eased = t * t * (3 - 2 * t)
                let expectedWidth = idle.musicAccessoryFrame.width
                    + (idle.compactWidth - idle.musicAccessoryFrame.width) * eased
                let rect = global(music.contourRect(progress: p), geometry: music, progress: p)
                XCTAssertEqual(rect.width, expectedWidth, accuracy: tolerance)
                XCTAssertEqual(rect.height, idle.contourRect(progress: p).height, accuracy: tolerance)
                XCTAssertEqual(rect.midX, idle.calibratedNotch.midX, accuracy: tolerance)
            }
            for p in [lower, idle.musicProgress(contentHeight: 68), idle.musicProgress(contentHeight: 90),
                      idle.updateProgress, 0.8, 1] {
                assertRect(global(music.contourRect(progress: p), geometry: music, progress: p),
                           global(idle.contourRect(progress: p), geometry: idle, progress: p))
                assertRect(music.frame(progress: p), idle.frame(progress: p))
            }
            let epsilon = 0.0000001
            let before = global(music.contourRect(progress: lower - epsilon), geometry: music, progress: lower - epsilon)
            let at = global(music.contourRect(progress: lower), geometry: music, progress: lower)
            XCTAssertLessThan(abs(before.width - at.width), tolerance)
            XCTAssertEqual(music.musicGestureCorridor, idle.musicGestureCorridor)
        }
    }

    func testAccessoryTransitionUsesTheSameContourAndHasExactIdleAndMusicEndpoints() {
        let idle = geometry()
        let lower = idle.musicProgress(contentHeight: 48)
        let progressSamples = (0...40).map { Double($0) / 40 } + [0.02, lower * 0.75, lower]
        for p in progressSamples {
            let t = CGFloat(min(1, p / lower))
            let eased = t * t * (3 - 2 * t)
            let idleRect = global(idle.contourRect(progress: p), geometry: idle, progress: p)
            var previousWidth = idleRect.width
            for step in 0...20 {
                let accessoryProgress = Double(step) / 20
                var music = idle
                music.showsMusicAccessories = true
                music.musicAccessoryProgress = accessoryProgress
                let rect = global(music.contourRect(progress: p), geometry: music, progress: p)
                let expected = idleRect.width + (idle.musicAccessoryFrame.width - idle.contourFrame.width)
                    * CGFloat(accessoryProgress) * (1 - eased)
                XCTAssertEqual(rect.width, expected, accuracy: tolerance)
                XCTAssertGreaterThanOrEqual(rect.width + tolerance, previousWidth)
                XCTAssertEqual(rect.height, idleRect.height, accuracy: tolerance)
                XCTAssertEqual(rect.midX, idleRect.midX, accuracy: tolerance)
                XCTAssertEqual(music.musicGestureCorridor, idle.musicGestureCorridor)
                XCTAssertEqual(music.notch, idle.notch)
                XCTAssertEqual(music.calibratedNotch, idle.calibratedNotch)
                XCTAssertEqual(music.contourFrame, idle.contourFrame)
                XCTAssertTrue(music.screen.insetBy(dx: -tolerance, dy: -tolerance)
                    .contains(music.frame(progress: p)))
                previousWidth = rect.width
                if step == 0 { assertRect(rect, idleRect) }
                if p >= lower { assertRect(rect, idleRect) }
            }
        }
    }

    func testMusicFrameAndHoverFollowTheSameVisibleContourThroughoutExpansion() {
        for scale in [CGFloat(1), 2] {
            for origin in [CGPoint.zero, CGPoint(x: -2048, y: -900)] {
                var music = geometry(origin: origin, scale: scale, width: 219.5, horizontal: 0.5)
                music.showsMusicAccessories = true
                for step in 0...40 {
                    let p = Double(step) / 40
                    let frame = music.frame(progress: p)
                    let rect = music.contourRect(progress: p)
                    let contour = IslandContour(rect: rect, progress: p,
                        cornerAdjustment: music.shapeCalibration.corner, referenceDepth: music.notch.height)
                    XCTAssertTrue(music.screen.insetBy(dx: -tolerance, dy: -tolerance).contains(frame))
                    XCTAssertTrue(CGRect(origin: .zero, size: frame.size)
                        .insetBy(dx: -tolerance, dy: -tolerance).contains(contour.bounds))
                    let middleY = rect.midY
                    let left = rect.minX + contour.shoulder
                    let right = rect.maxX - contour.shoulder
                    let probes: [(CGPoint, Bool)] = [
                        (CGPoint(x: left + 0.1, y: middleY), true),
                        (CGPoint(x: left - 0.1, y: middleY), false),
                        (CGPoint(x: right - 0.1, y: middleY), true),
                        (CGPoint(x: right + 0.1, y: middleY), false),
                        (CGPoint(x: rect.midX, y: rect.maxY - 0.1), true),
                        (CGPoint(x: rect.midX, y: rect.maxY + 0.1), false)
                    ]
                    for (point, expected) in probes {
                        let world = CGPoint(x: frame.minX + point.x, y: frame.maxY - point.y)
                        XCTAssertEqual(contour.contains(point), expected)
                        XCTAssertEqual(music.hoverContains(world, progress: p), expected)
                    }
                    // The 2pt-inset stroke shares the shell's circular-turn centers.
                    let outer = contour.commands(), rail = contour.commands(inset: 2)
                    XCTAssertEqual(outer.count, 8)
                    XCTAssertEqual(rail.count, 8)
                    for index in [1, 3, 5, 7] {
                        guard case .arc(let outerCenter, _, _, _, _) = outer[index],
                              case .arc(let railCenter, _, _, _, _) = rail[index] else {
                            XCTFail("Expected one connected circular U contour")
                            continue
                        }
                        XCTAssertEqual(outerCenter.x, railCenter.x, accuracy: tolerance)
                        // Top concave turns expand inward; their y center moves with the inset.
                        XCTAssertEqual(railCenter.y - outerCenter.y,
                                       index == 1 || index == 7 ? 2 : 0, accuracy: tolerance)
                    }
                }
            }
        }
    }

    func testEligibleClosedShellContainsArtworkAndPlayingGlyphAtCalibrationExtremes() {
        for scale in [CGFloat(1), 2] {
            for rawDepth in [CGFloat(20), 22, 28, 32, 38] {
                for adjustment in [-6.0, 0, 6] {
                    for corner in [-6.0, 0, 6] {
                        var music = geometry(scale: scale, depth: rawDepth,
                            calibration: .init(depth: adjustment, corner: corner))
                        guard music.canShowMusicAccessories else { continue }
                        music.showsMusicAccessories = true
                        let contour = IslandContour(rect: music.contourRect(progress: 0),
                            cornerAdjustment: corner, referenceDepth: rawDepth)
                        let accessories = music.musicAccessoryRects(progress: 0)
                        let top = max(0, (rawDepth - 20) / 2)
                        let artwork = CGRect(x: accessories.left.minX + 7, y: top, width: 20, height: 20)
                        let glyph = CGRect(x: accessories.right.maxX - 27, y: top, width: 20, height: 20)
                        for content in [artwork, glyph] {
                            for x in [content.minX + 0.01, content.maxX - 0.01] {
                                for y in [content.minY + 0.01, content.maxY - 0.01] {
                                    XCTAssertTrue(contour.contains(CGPoint(x: x, y: y)),
                                        "Eligible music content is clipped: depth=\(rawDepth), adjustment=\(adjustment), corner=\(corner)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testMusicEligibilityReservesCurvedEnvelopeAndNativeRoundingNearEitherScreenEdge() {
        for scale in [CGFloat(1), 2] {
            for origin in [CGPoint.zero, CGPoint(x: -2048, y: -900)] {
                let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
                for right in [false, true] {
                    for clearance in [CGFloat(33.5), 34, 34.25, 34.5, 35, 36, 42.25] {
                        let x = right ? screen.maxX - clearance - 220 : screen.minX + clearance
                        let raw = CGRect(x: x, y: screen.maxY - 32, width: 220, height: 32)
                        var music = IslandGeometry(notch: .init(notch: raw, leftPanel: .zero, rightPanel: .zero),
                            screen: screen, backingScale: scale)
                        let idle = music
                        music.showsMusicAccessories = music.canShowMusicAccessories
                        for step in 0...40 {
                            let p = Double(step) / 40
                            let frame = music.frame(progress: p)
                            XCTAssertTrue(screen.insetBy(dx: -tolerance, dy: -tolerance).contains(frame),
                                "Music shell escaped screen: scale=\(scale), right=\(right), clearance=\(clearance), p=\(p)")
                            XCTAssertEqual(frame.maxY, screen.maxY)
                            XCTAssertEqual(music.notch, raw)
                            XCTAssertEqual(music.contourFrame, idle.contourFrame)
                            XCTAssertEqual(music.musicGestureCorridor, idle.musicGestureCorridor)
                        }
                        if !music.canShowMusicAccessories {
                            assertRect(music.frame(progress: 0), idle.frame(progress: 0))
                        }
                    }
                }
            }
        }
    }
    func testFinalPaintDrainWaitsForBothChannelsIncludingRetainedClosedMusicShell() {
        for fps in [60.0, 120.0] {
            for retainsAccessories in [false, true] {
                var expansion = IslandMotion(), accessory = IslandMotion()
                let target = geometry(contentHeight: 340).musicProgress(contentHeight: 48)
                expansion.advance(target: target, elapsed: 0, reduceMotion: true)
                accessory.advance(expanded: true, elapsed: 0, reduceMotion: true)
                var drain = ClosePresentationDrain()
                var requests = 0
                let endpoint = retainsAccessories ? 1.0 : 0.0
                for index in 1...120 {
                    let previous = max(expansion.progress, abs(accessory.progress - endpoint))
                    expansion.advance(target: 0, elapsed: 1 / fps, reduceMotion: false)
                    accessory.advance(target: endpoint, elapsed: 1 / fps, reduceMotion: false)
                    let residual = max(expansion.progress, abs(accessory.progress - endpoint))
                    let now = Double(index) / fps
                    if let generation = drain.begin(previousProgress: previous, progress: residual,
                        expanded: false, reduceMotion: false, now: now) {
                        requests += 1
                        XCTAssertTrue(expansion.isSettled(at: 0))
                        XCTAssertTrue(accessory.isSettled(at: endpoint))
                        XCTAssertEqual(drain.poll(generation: generation, now: now + 1 / fps,
                            renderedAt: now + 0.001, renderedProgress: 0, viewportMatches: true), .ready)
                    }
                }
                XCTAssertEqual(requests, 1, "Every final shell, including retained music wings, receives one paint drain")
            }
        }
    }

}
