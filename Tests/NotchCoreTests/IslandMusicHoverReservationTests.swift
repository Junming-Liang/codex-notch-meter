import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NotchCore

final class IslandMusicHoverReservationTests: XCTestCase {
    private let corridor = CGRect(x: 100, y: 880, width: 280, height: 18)

    // Mirrors controller ordering with separate recognizers and one shared lease.
    // Polls are admitted only after 250 ms of event quiet, as in production.
    private struct Harness {
        var event = IslandCrossing(), poll = IslandCrossing()
        var lease = IslandMusicHoverReservation(), hover = IslandHoverState()
        var gate = IslandGestureHoverGate()
        var lastEvent = -Double.infinity
        var actions: [IslandCrossing.Direction] = []
        mutating func sample(_ point: CGPoint, at time: Double, isEvent: Bool, corridor: CGRect,
                             enabled: Bool = true, buttonDown: Bool = false) {
            if isEvent { lastEvent = time; poll.reset() }
            else { guard time - lastEvent > 0.25 else { return }; event.reset() }
            var recognizer = isEvent ? event : poll
            let action = recognizer.update(point: point, now: time, corridor: corridor,
                enabled: enabled, buttonDown: buttonDown)
            if isEvent { event = recognizer } else { poll = recognizer }
            let inside = point.x >= corridor.minX && point.x <= corridor.maxX
                && point.y >= corridor.minY && point.y <= corridor.maxY
            let reserves = lease.reservesPointer(recognizer.reservesPointer, insideCorridor: inside,
                enabled: enabled && !buttonDown, now: time)
            if let action { actions.append(action); hover.reset(); gate.claim(requiresLyrics: action == .right); return }
            if reserves || gate.suppresses(insideStableEnvelope: inside) { return }
            if !hover.isExpanded, lease.shouldResetDwell(at: point) { hover.reset() }
            hover.update(inside: inside, now: time)
        }
    }

    func testMixedSourcesCannotRenewStationaryOrMicroMovementReservationAtEitherEdge() {
        for x in [corridor.minX + 10, corridor.maxX - 10] {
            for jitter in [CGFloat(0), 1] {
                var h = Harness()
                for tick in 0...180 {
                    let time = Double(tick) / 30
                    // A real event every 300 ms; intervening 30 Hz polls include
                    // one admitted sample after 250 ms, resetting event history.
                    let sample = CGPoint(x: x + ((tick / 9).isMultiple(of: 2) ? jitter : -jitter), y: corridor.midY)
                    h.sample(sample, at: time, isEvent: tick.isMultiple(of: 9), corridor: corridor)
                    if time >= 1.6 { XCTAssertTrue(h.hover.isExpanded) }
                }
                XCTAssertTrue(h.actions.isEmpty)
            }
        }
    }

    func testVerticalEntryCannotGainFreshReservationOnEverySourceSwitch() {
        var h = Harness()
        h.sample(CGPoint(x: 110, y: corridor.minY - 10), at: 0, isEvent: true, corridor: corridor)
        h.sample(CGPoint(x: 110, y: corridor.midY), at: 0.03, isEvent: true, corridor: corridor)
        XCTAssertFalse(h.event.reservesPointer)
        for tick in 1...90 {
            h.sample(CGPoint(x: 110, y: corridor.midY), at: 0.03 + Double(tick) / 30,
                isEvent: tick.isMultiple(of: 9), corridor: corridor)
        }
        XCTAssertTrue(h.hover.isExpanded)
        XCTAssertTrue(h.actions.isEmpty)
    }

    func testExpiredLeaseDoesNotDisableFastCompleteCrossingOrItsCompletedGate() {
        for right in [true, false] {
            var h = Harness()
            let edge = right ? corridor.minX + 10 : corridor.maxX - 10
            XCTAssertTrue(h.lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 0))
            XCTAssertFalse(h.lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 2))
            for (index, fraction) in [CGFloat(0), 0.5, 1].enumerated() {
                let x = right ? edge + fraction * 260 : edge - fraction * 260
                h.sample(CGPoint(x: x, y: corridor.midY), at: 2 + Double(index) / 30,
                    isEvent: true, corridor: corridor)
            }
            XCTAssertEqual(h.actions, [right ? .right : .left])
            XCTAssertTrue(h.gate.isSuppressing)
            XCTAssertFalse(h.hover.isExpanded)
            h.sample(CGPoint(x: right ? 370 : 110, y: corridor.midY), at: 3, isEvent: false, corridor: corridor)
            XCTAssertTrue(h.gate.isSuppressing)
            XCTAssertFalse(h.hover.isExpanded)
        }
    }

    func testFullFastOvershootAndSlowContinuousTraversalsKeepTheirOriginalDirections() {
        for right in [true, false] {
            for interval in [0.03, 0.23] {
                var h = Harness()
                let fractions: [CGFloat] = [-0.1, 0.15, 0.4, 0.65, 0.9, 1.1]
                for (index, fraction) in fractions.enumerated() {
                    let x = corridor.minX + (right ? fraction : 1 - fraction) * corridor.width
                    h.sample(CGPoint(x: x, y: corridor.midY), at: Double(index) * interval,
                        isEvent: true, corridor: corridor)
                }
                XCTAssertEqual(h.actions, [right ? .right : .left])
                XCTAssertFalse(h.hover.isExpanded)
            }
        }
    }

    func testExitEligibilityAndExplicitBoundariesRearmButSourceChangesDoNot() {
        var lease = IslandMusicHoverReservation()
        XCTAssertTrue(lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 10))
        XCTAssertFalse(lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 11.2))
        XCTAssertFalse(lease.reservesPointer(false, insideCorridor: true, enabled: true, now: 12))
        XCTAssertFalse(lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 13))
        XCTAssertFalse(lease.reservesPointer(true, insideCorridor: false, enabled: true, now: 14))
        XCTAssertTrue(lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 15))
        XCTAssertFalse(lease.reservesPointer(true, insideCorridor: true, enabled: false, now: 16))
        XCTAssertTrue(lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 17))
        lease.reset() // Track, permission, notice, button, and lifecycle boundary.
        XCTAssertTrue(lease.reservesPointer(true, insideCorridor: true, enabled: true, now: 20))
    }

    func testDwellToleranceUsesFixedAnchorAndCannotAccumulateSlowDrift() {
        var lease = IslandMusicHoverReservation()
        XCTAssertFalse(lease.shouldResetDwell(at: CGPoint(x: 100, y: 100)))
        for x in [101, 99, 102, 103] { XCTAssertFalse(lease.shouldResetDwell(at: CGPoint(x: CGFloat(x), y: 100))) }
        XCTAssertTrue(lease.shouldResetDwell(at: CGPoint(x: 104, y: 100)))
        XCTAssertFalse(lease.shouldResetDwell(at: CGPoint(x: 105, y: 100)))
        XCTAssertTrue(lease.shouldResetDwell(at: CGPoint(x: 108, y: 100)))
    }

    func testDisabledRecognitionDoesNotEraseMovingHoverAnchorAndStoppingRecovers() {
        var h = Harness()
        for tick in 0...30 {
            h.sample(CGPoint(x: 110 + CGFloat(tick) * 4, y: corridor.midY), at: Double(tick) / 30,
                isEvent: true, corridor: corridor, enabled: false)
            XCTAssertFalse(h.hover.isExpanded)
        }
        for tick in 31...40 {
            h.sample(CGPoint(x: 230, y: corridor.midY), at: Double(tick) / 30,
                isEvent: true, corridor: corridor, enabled: false)
        }
        XCTAssertTrue(h.hover.isExpanded)
    }

    func testOutsideGestureCorridorStillRetainsAnchorWithinLargerHoverEnvelope() {
        var lease = IslandMusicHoverReservation(), hover = IslandHoverState()
        // These points are outside the narrow gesture band, but can still be
        // within the expanding card's larger hover area.
        for tick in 0...30 {
            let point = CGPoint(x: 110 + CGFloat(tick) * 4, y: corridor.minY - 10)
            XCTAssertFalse(lease.reservesPointer(false, insideCorridor: false,
                enabled: true, now: Double(tick) / 30))
            if lease.shouldResetDwell(at: point) { hover.reset() }
            hover.update(inside: true, now: Double(tick) / 30)
            XCTAssertFalse(hover.isExpanded)
        }
        for tick in 31...40 {
            XCTAssertFalse(lease.reservesPointer(false, insideCorridor: false,
                enabled: true, now: Double(tick) / 30))
            if lease.shouldResetDwell(at: CGPoint(x: 230, y: corridor.minY - 10)) { hover.reset() }
            hover.update(inside: true, now: Double(tick) / 30)
        }
        XCTAssertTrue(hover.isExpanded)
    }

    func testFailedLyricsRecoveryCanReleaseCompletedGateWithoutRenewingReservation() {
        var h = Harness()
        h.gate.claim(requiresLyrics: true)
        XCTAssertTrue(h.gate.releaseIfLyricsUnavailable(lyricsAvailable: false))
        h.lease.reset()
        // The controller's corridor-exit barrier disables recognition until exit.
        for tick in 0...90 {
            h.sample(CGPoint(x: 370, y: corridor.midY), at: Double(tick) / 30,
                isEvent: tick.isMultiple(of: 9), corridor: corridor, enabled: false)
        }
        XCTAssertTrue(h.hover.isExpanded)
        XCTAssertTrue(h.actions.isEmpty)
    }
}
