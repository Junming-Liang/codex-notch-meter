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
    func testThirtyHertzCrossingDoesNotNeedSamplesInEitherEdgeZone() {
        for right in [true, false] {
            var detector = IslandCrossing()
            let positions: [CGFloat] = [-0.1, 0.5, 1.1]
            let actions = positions.enumerated().compactMap { index, fraction in
                detector.update(point: point(right ? fraction : 1 - fraction),
                    now: 1 + Double(index) / 30, corridor: corridor, enabled: true)
            }
            XCTAssertEqual(actions, [right ? .right : .left])
        }
    }
    func testFastEdgeToEdgeCrossingsAreAcceptedWithoutArtificialDwell() {
        for elapsed in [0.02, 0.03, 0.05] {
            for right in [true, false] {
                var detector = IslandCrossing()
                XCTAssertNil(detector.update(point: point(right ? 0.02 : 0.98),
                    now: 1, corridor: corridor, enabled: true))
                XCTAssertEqual(detector.update(point: point(right ? 0.98 : 0.02),
                    now: 1 + elapsed, corridor: corridor, enabled: true), right ? .right : .left)
            }
        }
    }
    func testSingleObservedSegmentCanCrossBothHorizontalEdges() {
        for right in [true, false] {
            var detector = IslandCrossing()
            XCTAssertNil(detector.update(point: point(right ? -0.1 : 1.1),
                now: 1, corridor: corridor, enabled: true))
            XCTAssertEqual(detector.update(point: point(right ? 1.1 : -0.1),
                now: 1 + 1.0 / 30, corridor: corridor, enabled: true), right ? .right : .left)
        }
    }
    func testEndpointOvershootCompletesAnAlreadyTrackedCrossing() {
        for right in [true, false] {
            var detector = IslandCrossing()
            let positions: [CGFloat] = [0.02, 0.4, 0.8, 1.2]
            let actions = positions.enumerated().compactMap { index, fraction in
                detector.update(point: point(right ? fraction : 1 - fraction),
                    now: 1 + Double(index) / 30, corridor: corridor, enabled: true)
            }
            XCTAssertEqual(actions, [right ? .right : .left])
        }
    }
    func testThirtyHertzSamplingPhaseDoesNotChangeCompleteCrossingResult() {
        // Replay complete constant-speed paths, including the outside samples
        // real polling observes. The prior edge-only detector missed many phases.
        for duration in [0.08, 0.12, 0.16, 0.24, 0.32, 0.48] {
            for phase in 0..<16 {
                for right in [true, false] {
                    var detector = IslandCrossing()
                    var actions: [IslandCrossing.Direction] = []
                    for index in -2...(Int(ceil(duration * 30)) + 2) {
                        let elapsed = Double(index) / 30 + Double(phase) / (16 * 30)
                        let fraction = CGFloat(elapsed / duration)
                        if let action = detector.update(point: point(right ? fraction : 1 - fraction),
                            now: 10 + elapsed, corridor: corridor, enabled: true) {
                            actions.append(action)
                        }
                    }
                    XCTAssertEqual(actions, [right ? .right : .left],
                        "duration=\(duration), phase=\(phase), right=\(right)")
                }
            }
        }
    }
    func testSparseReverseAfterObservedExitIsFreshCrossing() {
        var detector = IslandCrossing()
        let positions: [CGFloat] = [-0.1, 0.5, 1.1, 1.2, 0.5, -0.1]
        let actions = positions.enumerated().compactMap { index, fraction in
            detector.update(point: point(fraction), now: 1 + Double(index) / 30,
                corridor: corridor, enabled: true)
        }
        XCTAssertEqual(actions, [.right, .left])
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
    func testObservedVerticalEntryAtSideDoesNotArmHorizontalCrossing() {
        for right in [true, false] {
            var detector = IslandCrossing()
            let fractions: [CGFloat] = [0.02, 0.02, 0.5, 0.98, 1.1]
            for (index, fraction) in fractions.enumerated() {
                let y = index == 0 ? corridor.minY - 12 : corridor.midY
                XCTAssertNil(detector.update(point: point(right ? fraction : 1 - fraction, y: y),
                    now: 1 + Double(index) / 30, corridor: corridor, enabled: true))
            }
        }
    }
    func testDiagonalEnteringThroughBottomCannotMasqueradeAsSideEntry() {
        for right in [true, false] {
            var detector = IslandCrossing()
            // The first segment crosses the corridor's horizontal x extent
            // below its bottom, then actually enters through the bottom edge.
            let samples: [(CGFloat, CGFloat)] = [
                (-0.2, corridor.minY - 100), (0.5, corridor.midY),
                (0.98, corridor.midY), (1.1, corridor.midY)
            ]
            for (index, sample) in samples.enumerated() {
                XCTAssertNil(detector.update(point: point(right ? sample.0 : 1 - sample.0, y: sample.1),
                    now: 1 + Double(index) / 30, corridor: corridor, enabled: true))
            }
        }
    }
    func testPermissionSuppressionOrButtonResetsPartialCrossing() {
        for buttons in [false, true] {
            var detector = IslandCrossing()
            XCTAssertNil(detector.update(point: point(0.02), now: 0, corridor: corridor, enabled: true))
            XCTAssertNil(detector.update(point: point(0.5), now: 0.04, corridor: corridor, enabled: buttons, buttonDown: buttons))
            XCTAssertNil(detector.update(point: point(0.98), now: 0.08, corridor: corridor, enabled: true))
        }
    }
    func testDisabledAndButtonDownSamplesDiscardOutsideHistory() {
        for buttons in [false, true] {
            var detector = IslandCrossing()
            XCTAssertNil(detector.update(point: point(-0.1), now: 1,
                corridor: corridor, enabled: true))
            XCTAssertNil(detector.update(point: point(1.1), now: 1.03,
                corridor: corridor, enabled: buttons, buttonDown: buttons))
            XCTAssertNil(detector.update(point: point(-0.1), now: 1.06,
                corridor: corridor, enabled: true))
        }
    }
    func testStalledOutsideSamplesCannotInventUnobservedCrossing() {
        for elapsed in [0.251, 0.5, 2.0] {
            var detector = IslandCrossing()
            XCTAssertNil(detector.update(point: point(-0.1), now: 1,
                corridor: corridor, enabled: true))
            XCTAssertNil(detector.update(point: point(1.1), now: 1 + elapsed,
                corridor: corridor, enabled: true))
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
    func testExplicitResetAlsoDiscardsOutsideHistory() {
        var detector = IslandCrossing()
        XCTAssertNil(detector.update(point: point(-0.1), now: 1,
            corridor: corridor, enabled: true))
        detector.reset()
        XCTAssertNil(detector.update(point: point(1.1), now: 1.03,
            corridor: corridor, enabled: true))
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
    func testGestureHoverGateStartsUnclaimedAndClaimIsIdempotent() {
        var gate = IslandGestureHoverGate()
        XCTAssertFalse(gate.isSuppressing)
        XCTAssertFalse(gate.suppresses(insideStableEnvelope: true))
        gate.claim()
        gate.claim()
        XCTAssertTrue(gate.isSuppressing)
        for _ in 0..<60 {
            XCTAssertTrue(gate.suppresses(insideStableEnvelope: true))
        }
    }
    func testGestureHoverGateSurvivesNaturalSideAndDownwardExitFromCorridor() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let raw = CGRect(x: 610, y: 868, width: 220, height: 32)
        var geometry = IslandGeometry(notch: NotchGeometry(notch: raw, leftPanel: .zero, rightPanel: .zero), screen: screen)
        geometry.showsMusicAccessories = true
        let corridor = geometry.musicGestureCorridor
        let samples = [
            CGPoint(x: corridor.maxX - 6, y: corridor.midY),
            CGPoint(x: corridor.maxX + 5, y: corridor.midY),
            CGPoint(x: corridor.maxX + 5, y: corridor.minY - 20)
        ]
        var gate = IslandGestureHoverGate()
        gate.claim()
        for sample in samples {
            XCTAssertTrue(geometry.hoverContains(sample, progress: 1))
            XCTAssertTrue(gate.suppresses(insideStableEnvelope: geometry.hoverContains(sample, progress: 1)))
        }
        XCTAssertFalse(corridor.contains(samples[1]))
        XCTAssertFalse(corridor.contains(samples[2]))
        XCTAssertTrue(gate.isSuppressing)
    }
    func testGestureHoverGateDoesNotFollowAppearingOrShrinkingBody() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let raw = CGRect(x: 610, y: 868, width: 220, height: 32)
        var geometry = IslandGeometry(notch: NotchGeometry(notch: raw, leftPanel: .zero, rightPanel: .zero), screen: screen)
        geometry.showsMusicAccessories = true
        let sample = CGPoint(x: geometry.musicGestureCorridor.maxX + 5,
            y: geometry.musicGestureCorridor.midY)
        XCTAssertFalse(geometry.hoverContains(sample, progress: 0))
        XCTAssertTrue(geometry.hoverContains(sample, progress: 1))
        var gate = IslandGestureHoverGate()
        gate.claim()
        var visibleContainment = Set<Bool>()
        for progress in [0.0, 0.05, 0.3, 0.7, 1.0, 0.7, 0.3, 0.05, 0.0] {
            visibleContainment.insert(geometry.hoverContains(sample, progress: progress))
            // The pointer has not moved. Production must consult the stable
            // full envelope rather than the changing visible progress above.
            XCTAssertTrue(gate.suppresses(insideStableEnvelope: geometry.hoverContains(sample, progress: 1)))
        }
        XCTAssertEqual(visibleContainment, Set([false, true]))
    }
    func testGestureHoverGateReleasesAfterExitAndFreshEntryCanDwellOpen() {
        var gate = IslandGestureHoverGate()
        var hover = IslandHoverState()
        gate.claim()
        XCTAssertTrue(gate.suppresses(insideStableEnvelope: true))
        XCTAssertFalse(gate.suppresses(insideStableEnvelope: false))
        XCTAssertFalse(gate.isSuppressing)
        XCTAssertFalse(gate.suppresses(insideStableEnvelope: true))
        hover.update(inside: true, now: 1)
        XCTAssertFalse(hover.isExpanded)
        hover.update(inside: true, now: 1.13)
        XCTAssertTrue(hover.isExpanded)
    }
    func testGestureHoverGateResetAndNewClaimAreIndependent() {
        var gate = IslandGestureHoverGate()
        gate.claim()
        gate.reset()
        XCTAssertFalse(gate.isSuppressing)
        XCTAssertFalse(gate.suppresses(insideStableEnvelope: true))
        gate.claim()
        XCTAssertTrue(gate.suppresses(insideStableEnvelope: true))
        XCTAssertFalse(gate.suppresses(insideStableEnvelope: false))
        gate.claim()
        XCTAssertTrue(gate.suppresses(insideStableEnvelope: true))
    }
    func testUsableOpeningRetainsGestureProtectionUntilExit() {
        var gate = IslandGestureHoverGate()
        gate.claim(requiresLyrics: true)
        for _ in 0..<60 {
            XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: true))
            XCTAssertTrue(gate.suppresses(insideStableEnvelope: true))
        }
        XCTAssertFalse(gate.suppresses(insideStableEnvelope: false))
        XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
    }
    func testUnavailableOpeningReleasesOnlyItsInputOwnership() {
        var gate = IslandGestureHoverGate()
        var hover = IslandHoverState()
        gate.claim(requiresLyrics: true)
        XCTAssertTrue(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
        XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
        XCTAssertFalse(gate.suppresses(insideStableEnvelope: true))
        hover.update(inside: true, now: 1)
        XCTAssertFalse(hover.isExpanded)
        hover.update(inside: true, now: 1.13)
        XCTAssertTrue(hover.isExpanded)
        // Fresh content alone cannot resurrect the retired gesture claim.
        XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: true))
        XCTAssertFalse(gate.isSuppressing)
    }
    func testExplicitCloseAndNoticeClaimsSurviveUnavailableLyrics() {
        for _ in ["explicitClose", "quotaNotice"] {
            var gate = IslandGestureHoverGate()
            gate.claim()
            for available in [true, false, false, true] {
                XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: available))
                XCTAssertTrue(gate.suppresses(insideStableEnvelope: true))
            }
            XCTAssertFalse(gate.suppresses(insideStableEnvelope: false))
        }
    }
    func testLatestGestureClaimReplacesItsEligibilityRequirement() {
        var gate = IslandGestureHoverGate()
        gate.claim(requiresLyrics: true)
        gate.claim() // A reverse crossing or notice supersedes the opening.
        XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
        XCTAssertTrue(gate.isSuppressing)
        gate.claim(requiresLyrics: true)
        XCTAssertTrue(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
        gate.claim()
        XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
        gate.reset()
        XCTAssertFalse(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
    }
    func testRecoveryBarrierCompositionSurvivesEventAndPollHistoryResets() {
        // Core composition of the controller's shared recovery barrier. Native
        // fixtures separately exercise its production AppKit action handler.
        var event = IslandCrossing(), poll = IslandCrossing()
        var gate = IslandGestureHoverGate(), hover = IslandHoverState()
        var needsCorridorExit = true
        gate.claim(requiresLyrics: true)
        XCTAssertTrue(gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
        for index in 0..<24 {
            let sample = point(0.98), now = Double(index) / 30
            let inside = sample.x >= corridor.minX && sample.x <= corridor.maxX
                && sample.y >= corridor.minY && sample.y <= corridor.maxY
            if needsCorridorExit && !inside {
                needsCorridorExit = false; event.reset(); poll.reset()
            }
            // Production deliberately resets the opposite source's history.
            if index.isMultiple(of: 2) {
                poll.reset()
                XCTAssertNil(event.update(point: sample, now: now, corridor: corridor,
                    enabled: !needsCorridorExit))
                XCTAssertFalse(event.reservesPointer)
            } else {
                event.reset()
                XCTAssertNil(poll.update(point: sample, now: now, corridor: corridor,
                    enabled: !needsCorridorExit))
                XCTAssertFalse(poll.reservesPointer)
            }
            XCTAssertFalse(gate.suppresses(insideStableEnvelope: true))
            hover.update(inside: true, now: now)
        }
        XCTAssertTrue(hover.isExpanded)
        XCTAssertTrue(needsCorridorExit)
        // Corridor endpoints are still inside; only an observed real exit
        // permits recognition to restart, with both histories freshly empty.
        for sample in [point(0), point(1), point(0.5, y: corridor.minY), point(0.5, y: corridor.maxY)] {
            XCTAssertTrue(sample.x >= corridor.minX && sample.x <= corridor.maxX
                && sample.y >= corridor.minY && sample.y <= corridor.maxY)
        }
        let outside = point(1.1)
        XCTAssertTrue(outside.x > corridor.maxX)
        needsCorridorExit = false; event.reset(); poll.reset()
        XCTAssertEqual(traverse(&event, right: false, start: 1), [.left])
        XCTAssertEqual(traverse(&poll, right: true, start: 1), [.right])
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
            XCTAssertEqual(original.contourRect(progress: 0).width, 226)
            XCTAssertEqual(music.contourRect(progress: 0).width, 288)
            XCTAssertEqual(music.contourRect(progress: 0).width, music.musicAccessoryFrame.width)
            let compactProgress = music.musicProgress(contentHeight: 48)
            for p in [0.0, 0.02, compactProgress / 2, compactProgress, 0.7, 1.0] {
                let a = original.frame(progress: p), b = music.frame(progress: p)
                let ar = original.contourRect(progress: p), br = music.contourRect(progress: p)
                XCTAssertEqual(a.minX + ar.midX, b.minX + br.midX, accuracy: 1e-9)
                XCTAssertEqual(ar.height, br.height, accuracy: 1e-9)
                if p < compactProgress {
                    let fraction = CGFloat(p / compactProgress)
                    let ease = fraction * fraction * (3 - 2 * fraction)
                    XCTAssertEqual(br.width - ar.width, 62 * (1 - ease), accuracy: 1e-9)
                    XCTAssertGreaterThan(br.width, ar.width)
                } else {
                    XCTAssertEqual(ar.size, br.size)
                    XCTAssertEqual(a.minX + ar.minX, b.minX + br.minX, accuracy: 1e-9)
                }
                let originalRail = original.railRect(progress: p), musicRail = music.railRect(progress: p)
                XCTAssertEqual(originalRail.size, musicRail.size)
                XCTAssertEqual(a.minX + originalRail.minX, b.minX + musicRail.minX, accuracy: 1e-9)
                XCTAssertEqual(music.musicGestureCorridor, original.musicGestureCorridor)
            }
        }
    }
}
