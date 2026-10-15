import XCTest
@testable import NotchCore

final class ClosePresentationTests: XCTestCase {
    private func begin(_ drain: inout ClosePresentationDrain, at now: TimeInterval = 10) -> UInt64 {
        let generation = drain.begin(previousProgress: 0.0005, progress: 0, expanded: false,
            reduceMotion: false, now: now)
        XCTAssertNotNil(generation)
        return generation ?? 0
    }

    func testTerminalCloseWaitsForLaterViewUpdateAndIsConsumedOnce() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        XCTAssertTrue(drain.isPending)
        XCTAssertEqual(drain.startedAt, 10)
        XCTAssertEqual(drain.poll(generation: generation, now: 10, renderedAt: 10,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.01, renderedAt: 10.005,
            renderedProgress: 0, viewportMatches: true), .ready)
        XCTAssertFalse(drain.isPending)
        XCTAssertNil(drain.startedAt)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.02, renderedAt: 10.015,
            renderedProgress: 0, viewportMatches: true), .idle)
    }

    func testViewTimestampAtStartNeedsAnObservationStrictlyAfterStart() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        XCTAssertEqual(drain.poll(generation: generation, now: 10, renderedAt: 10,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.001, renderedAt: 10,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testOldViewUpdateCannotAcknowledgeClose() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.01, renderedAt: 9.999,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.02, renderedAt: 10.015,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testWrongViewportAndNonzeroProgressNeedAFreshMatchingUpdate() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.01, renderedAt: 10.005,
            renderedProgress: 0, viewportMatches: false), .pending)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.02, renderedAt: 10.015,
            renderedProgress: 0.000001, viewportMatches: true), .pending)
        // Correcting the values attached to an already-observed update is not a new update.
        XCTAssertEqual(drain.poll(generation: generation, now: 10.03, renderedAt: 10.015,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.04, renderedAt: 10.035,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testNoFrameClockAdvanceCannotProduceAnAcknowledgment() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        for _ in 0..<10 {
            XCTAssertEqual(drain.poll(generation: generation, now: 10, renderedAt: 10,
                renderedProgress: 0, viewportMatches: true), .pending)
        }
        XCTAssertTrue(drain.isPending)
        XCTAssertEqual(drain.startedAt, 10)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.01, renderedAt: 10,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testDuplicateBackwardAndNonfiniteObservationTimesDoNotAcknowledge() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.02, renderedAt: 10.01,
            renderedProgress: 0.1, viewportMatches: true), .pending)
        for now in [10.02, 10.015, 9.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(drain.poll(generation: generation, now: now, renderedAt: 10.015,
                renderedProgress: 0, viewportMatches: true), .pending)
        }
        XCTAssertEqual(drain.poll(generation: generation, now: 10.03, renderedAt: 10.025,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testDuplicateBackwardNonfiniteAndFutureViewTimesDoNotAcknowledge() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.01, renderedAt: 10.005,
            renderedProgress: 0, viewportMatches: false), .pending)
        let invalidTimes: [TimeInterval] = [10.005, 10.004, 9.0, .nan, .infinity, -.infinity, 11]
        for (index, renderedAt) in invalidTimes.enumerated() {
            XCTAssertEqual(drain.poll(generation: generation, now: 10.02 + Double(index) * 0.01,
                renderedAt: renderedAt, renderedProgress: 0, viewportMatches: true), .pending)
        }
        XCTAssertEqual(drain.poll(generation: generation, now: 10.10, renderedAt: 10.09,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testNonfiniteRenderedProgressCannotAcknowledge() {
        for progress in [Double.nan, .infinity, -.infinity] {
            var drain = ClosePresentationDrain()
            let generation = begin(&drain)
            XCTAssertEqual(drain.poll(generation: generation, now: 10.01, renderedAt: 10.005,
                renderedProgress: progress, viewportMatches: true), .pending)
            XCTAssertTrue(drain.isPending)
        }
    }

    func testMissingAcknowledgmentTimesOutAtExactDeadlineAndClearsState() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        let deadline = 10 + drain.timeout
        XCTAssertEqual(drain.poll(generation: generation, now: deadline.nextDown, renderedAt: 9,
            renderedProgress: 1, viewportMatches: false), .pending)
        XCTAssertTrue(drain.isPending)
        XCTAssertEqual(drain.poll(generation: generation, now: deadline, renderedAt: 9,
            renderedProgress: 1, viewportMatches: false), .timedOut)
        XCTAssertFalse(drain.isPending)
        XCTAssertEqual(drain.poll(generation: generation, now: deadline + 1, renderedAt: 9,
            renderedProgress: 1, viewportMatches: false), .idle)
    }

    func testAcknowledgmentAtDeadlineIsExplicitTimeoutNotSuccess() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        let deadline = 10 + drain.timeout
        XCTAssertEqual(drain.poll(generation: generation, now: deadline, renderedAt: deadline,
            renderedProgress: 0, viewportMatches: true), .timedOut)
        XCTAssertFalse(drain.isPending)
    }

    func testFreshMatchingAcknowledgmentJustBeforeDeadlineIsReady() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        let lastInstant = (10 + drain.timeout).nextDown
        XCTAssertEqual(drain.poll(generation: generation, now: lastInstant, renderedAt: lastInstant,
            renderedProgress: 0, viewportMatches: true), .ready)
        XCTAssertFalse(drain.isPending)
    }

    func testLatePollStillTerminatesCleanupWithoutAcknowledgment() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        XCTAssertEqual(drain.poll(generation: generation, now: 100, renderedAt: .nan,
            renderedProgress: .nan, viewportMatches: false), .timedOut)
        XCTAssertFalse(drain.isPending)
    }

    func testInitialIdleOpeningNonterminalAndReduceMotionNeverStartDrain() {
        let cases: [(Double, Double, Bool, Bool)] = [
            (0, 0, false, false), (0, 1, true, false), (0.01, 0, true, false),
            (1, 0.01, false, false), (1, 0, false, true), (0, 0, false, true)
        ]
        for (previous, progress, expanded, reduceMotion) in cases {
            var drain = ClosePresentationDrain()
            XCTAssertNil(drain.begin(previousProgress: previous, progress: progress, expanded: expanded,
                reduceMotion: reduceMotion, now: 10))
            XCTAssertFalse(drain.isPending)
            XCTAssertEqual(drain.generation, 0)
        }
    }

    func testInvalidStartTimesAndProgressCannotStartDrain() {
        for now in [-1.0, .nan, .infinity, -.infinity] {
            var drain = ClosePresentationDrain()
            XCTAssertNil(drain.begin(previousProgress: 1, progress: 0, expanded: false,
                reduceMotion: false, now: now))
            XCTAssertFalse(drain.isPending)
        }
        for previous in [-1.0, 1.1, .nan, .infinity, -.infinity] {
            var drain = ClosePresentationDrain()
            XCTAssertNil(drain.begin(previousProgress: previous, progress: 0, expanded: false,
                reduceMotion: false, now: 10))
        }
        for progress in [-0.01, .nan, .infinity, -.infinity] {
            var drain = ClosePresentationDrain()
            XCTAssertNil(drain.begin(previousProgress: 1, progress: progress, expanded: false,
                reduceMotion: false, now: 10))
        }
    }

    func testCancelOnReentryOrTeardownPreventsLateAcknowledgment() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        drain.cancel()
        drain.cancel()
        XCTAssertFalse(drain.isPending)
        XCTAssertNil(drain.startedAt)
        XCTAssertEqual(drain.poll(generation: generation, now: 10.01, renderedAt: 10.005,
            renderedProgress: 0, viewportMatches: true), .idle)
        XCTAssertNil(drain.begin(previousProgress: 0, progress: 0.01, expanded: true,
            reduceMotion: false, now: 10.02))
        XCTAssertFalse(drain.isPending)
    }

    func testRestartRejectsRetiredGenerationAndOldViewAcknowledgment() {
        var drain = ClosePresentationDrain()
        let oldGeneration = begin(&drain)
        drain.cancel()
        let newGeneration = begin(&drain, at: 10.05)
        XCTAssertNotEqual(oldGeneration, newGeneration)
        // A retired callback cannot consume the new close, even with newer-looking data.
        XCTAssertEqual(drain.poll(generation: oldGeneration, now: 10.06, renderedAt: 10.055,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: newGeneration, now: 10.06, renderedAt: 10.04,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: newGeneration, now: 10.07, renderedAt: 10.065,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testRestartWhilePendingGetsNewGenerationAndNewDeadline() {
        var drain = ClosePresentationDrain()
        let oldGeneration = begin(&drain)
        let newGeneration = begin(&drain, at: 10.10)
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertEqual(drain.startedAt, 10.10)
        XCTAssertEqual(drain.poll(generation: oldGeneration, now: 10.30, renderedAt: 10.25,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: newGeneration, now: 10.13, renderedAt: 10.09,
            renderedProgress: 0, viewportMatches: true), .pending)
        XCTAssertEqual(drain.poll(generation: newGeneration, now: 10.14, renderedAt: 10.135,
            renderedProgress: 0, viewportMatches: true), .ready)
    }

    func testDuplicateOrBackwardStartDoesNotReplacePendingGeneration() {
        var drain = ClosePresentationDrain()
        let generation = begin(&drain)
        for now in [10.0, 9.99] {
            XCTAssertNil(drain.begin(previousProgress: 0.1, progress: 0, expanded: false,
                reduceMotion: false, now: now))
            XCTAssertEqual(drain.generation, generation)
            XCTAssertEqual(drain.startedAt, 10)
        }
        drain.cancel()
        XCTAssertNil(drain.begin(previousProgress: 0.1, progress: 0, expanded: false,
            reduceMotion: false, now: 10))
        XCTAssertFalse(drain.isPending)
    }

    func testTimeoutIsAlwaysPositiveFiniteAndBounded() {
        for timeout in [0.0, -1, .nan, .infinity, -.infinity, 1] {
            XCTAssertEqual(ClosePresentationDrain(timeout: timeout).timeout, 0.12)
        }
        var drain = ClosePresentationDrain(timeout: 0.01)
        let generation = begin(&drain)
        XCTAssertEqual(drain.timeout, 0.01)
        XCTAssertEqual(drain.poll(generation: generation, now: 10 + drain.timeout, renderedAt: 9,
            renderedProgress: 0, viewportMatches: true), .timedOut)
    }
}
