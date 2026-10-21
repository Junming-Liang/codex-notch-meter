import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class MusicQuotaHoverStabilityTests: XCTestCase {
    private func geometry(width: CGFloat = 330, origin: CGPoint = .zero,
                          calibration: ContourCalibration = .init()) -> IslandGeometry {
        let screen = CGRect(origin: origin, size: CGSize(width: 1440, height: 900))
        let notch = CGRect(x: screen.midX - width / 2, y: screen.maxY - 32, width: width, height: 32)
        var value = IslandGeometry(notch: NotchGeometry(notch: notch, leftPanel: .zero, rightPanel: .zero),
            screen: screen, shapeCalibration: calibration)
        value.showsMusicAccessories = true
        value.musicAccessoryProgress = 1
        return value
    }

    // Same geometry, hover hysteresis and spring used by the production panel.
    // Only the stationary pointer and the delivery clock are supplied here.
    private func transitions(_ geometry: IslandGeometry, at point: CGPoint,
                             retainOrigin: Bool) -> (opens: Int, closes: Int, progress: Double) {
        var hover = IslandHoverState(), motion = IslandMotion()
        var opens = 0, closes = 0
        for step in 0..<500 {
            let before = hover.isExpanded
            let inside = geometry.hoverContains(point, progress: motion.progress,
                retainingMusicOrigin: retainOrigin && hover.isExpanded)
            hover.update(inside: inside, now: Double(step) * 0.01)
            if before != hover.isExpanded {
                if hover.isExpanded { opens += 1 } else { closes += 1 }
            }
            motion.advance(expanded: hover.isExpanded, elapsed: 0.01, reduceMotion: false)
        }
        return (opens, closes, motion.progress)
    }

    func testStationaryMusicWingPreviouslyReopenedQuotaButNowHoldsOneOpening() {
        for origin in [CGPoint.zero, CGPoint(x: -2048, y: 900)] {
            let g = geometry(origin: origin)
            for direction in [CGFloat(-1), 1] {
                let point = CGPoint(x: g.calibratedNotch.midX + direction * 194, y: g.screen.maxY - 16)
                XCTAssertTrue(g.hoverContains(point, progress: 0))
                XCTAssertFalse(g.hoverContains(point, progress: 1))
                let old = transitions(g, at: point, retainOrigin: false)
                XCTAssertGreaterThan(old.opens, 1, "Original dynamic-only hit test repeatedly reopens")
                XCTAssertGreaterThan(old.closes, 0)
                let fixed = transitions(g, at: point, retainOrigin: true)
                XCTAssertEqual(fixed.opens, 1)
                XCTAssertEqual(fixed.closes, 0)
                XCTAssertEqual(fixed.progress, 1)
                XCTAssertFalse(g.interactiveContains(point), "Retained hover area must not invent a click target")
            }
        }
    }

    func testRetentionDoesNotCapturePointsOutsideBothShellsOrOrdinaryHover() {
        let g = geometry()
        let outside = CGPoint(x: g.musicAccessoryFrame.maxX + 30, y: g.screen.maxY - 16)
        for step in 0...100 {
            XCTAssertFalse(g.hoverContains(outside, progress: Double(step) / 100, retainingMusicOrigin: true))
        }
        var ordinary = g
        ordinary.showsMusicAccessories = false
        for step in 0...100 {
            let p = Double(step) / 100
            for x in stride(from: g.screen.midX - 230, through: g.screen.midX + 230, by: 5) {
                let point = CGPoint(x: x, y: g.screen.maxY - 16)
                XCTAssertEqual(ordinary.hoverContains(point, progress: p, retainingMusicOrigin: true),
                               ordinary.hoverContains(point, progress: p))
            }
        }
    }

    func testClosedMusicOriginSurvivesCalibrationAndNarrowNotchControls() {
        for width in [CGFloat(220), 300, 330, 360] {
            for calibration in [ContourCalibration(), .init(width: -16, depth: -6, corner: -6),
                                .init(width: 16, depth: 6, corner: 6)] {
                let g = geometry(width: width, calibration: calibration)
                for x in [g.musicAccessoryFrame.minX + 3, g.musicAccessoryFrame.maxX - 3] {
                    let point = CGPoint(x: x, y: g.screen.maxY - 8)
                    XCTAssertTrue(g.hoverContains(point, progress: 0))
                    for step in 0...100 {
                        XCTAssertTrue(g.hoverContains(point, progress: Double(step) / 100, retainingMusicOrigin: true))
                    }
                    let fixed = transitions(g, at: point, retainOrigin: true)
                    XCTAssertEqual(fixed.opens, 1)
                    XCTAssertEqual(fixed.closes, 0)
                    if width == 220 {
                        let original = transitions(g, at: point, retainOrigin: false)
                        XCTAssertEqual(original.opens, 1)
                        XCTAssertEqual(original.closes, 0)
                    }
                }
            }
        }
    }

    func testExpandedHoverOwnsDetailsRegardlessOfRetainedLyricsPreference() {
        for selectedLyricsAvailable in [false, true] {
            XCTAssertEqual(IslandExpansionOwner.resolve(hoverExpanded: true, noticeActive: false,
                musicEligible: selectedLyricsAvailable, passiveMusicAllowed: true), .details)
        }
        XCTAssertEqual(IslandExpansionOwner.resolve(hoverExpanded: false, noticeActive: false,
            musicEligible: true, passiveMusicAllowed: true), .music)
        // The panel's hold requires expanded hover, so this passive lyric owner
        // never receives the retained music-origin region.
    }

    func testRealExitStillClosesAfterExistingHysteresis() {
        let g = geometry()
        let inside = CGPoint(x: g.calibratedNotch.midX + 194, y: g.screen.maxY - 16)
        let outside = CGPoint(x: g.screen.minX, y: g.screen.minY)
        var hover = IslandHoverState()
        hover.update(inside: g.hoverContains(inside, progress: 0), now: 0)
        hover.update(inside: g.hoverContains(inside, progress: 0), now: 0.13)
        XCTAssertTrue(hover.isExpanded)
        hover.update(inside: g.hoverContains(outside, progress: 1, retainingMusicOrigin: true), now: 1)
        XCTAssertTrue(hover.isExpanded)
        hover.update(inside: g.hoverContains(outside, progress: 1, retainingMusicOrigin: true), now: 1.23)
        XCTAssertFalse(hover.isExpanded)
    }
}
