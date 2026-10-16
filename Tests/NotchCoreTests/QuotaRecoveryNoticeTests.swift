import XCTest
@testable import NotchCore

final class QuotaRecoveryNoticeTests: XCTestCase {
    private func sample(_ time: Double, remaining: Double, identity: String? = "synthetic-a",
                        reset: Double? = 200_000) -> QuotaSnapshot {
        QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Synthetic", windows: [
            QuotaWindow(id: "codex:primary", usedPercent: 100 - remaining, durationMinutes: 300,
                        resetsAt: reset.map { Date(timeIntervalSince1970: $0) })
        ])], fetchedAt: Date(timeIntervalSince1970: time), continuityIdentity: QuotaContinuityIdentity(identity))
    }
    private func record(_ snapshot: QuotaSnapshot, into tracker: inout QuotaUpdateTracker) -> QuotaUpdate {
        tracker.record(snapshot, at: snapshot.fetchedAt)
    }
    private func assertGeneric(_ event: QuotaUpdate, reason: QuotaUpdateReason,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(event.changedWindow()?.change, .updated(reason: reason), file: file, line: line)
        XCTAssertNil(event.previousFetchedAt, file: file, line: line)
    }

    func testRealisticRepeatedTransportFailureSequenceKeepsLastSuccessfulObservation() {
        for identity in ["synthetic-a", nil] as [String?] {
            var tracker = QuotaUpdateTracker()
            XCTAssertNil(record(sample(100, remaining: 80, identity: identity), into: &tracker).changedWindow())
            XCTAssertNil(tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 172)).changedWindow())
            XCTAssertNil(tracker.recordFailure(.disconnected, at: Date(timeIntervalSince1970: 304)).changedWindow())
            assertGeneric(record(sample(556, remaining: 50, identity: identity), into: &tracker), reason: .previousReadFailed)
            XCTAssertNil(record(sample(616, remaining: 50, identity: identity), into: &tracker).changedWindow())
            let next = record(sample(676, remaining: 45, identity: identity), into: &tracker)
            if identity == nil { assertGeneric(next, reason: .identityUnavailable) }
            else { XCTAssertEqual(next.changedWindow()?.change, .decreased(percentagePoints: 5)) }
        }
    }

    func testFreshRecoveryIsGenericEvenWithVerifiedIdentity() {
        var tracker = QuotaUpdateTracker()
        _ = record(sample(100, remaining: 80), into: &tracker)
        _ = tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 110))
        assertGeneric(record(sample(125, remaining: 50), into: &tracker), reason: .previousReadFailed)
        let next = record(sample(185, remaining: 40), into: &tracker)
        XCTAssertEqual(next.changedWindow()?.change, .decreased(percentagePoints: 10))
        XCTAssertEqual(next.previousFetchedAt, Date(timeIntervalSince1970: 125))
    }

    func testFreshnessAndObservationBoundariesAreSeparate() {
        for (gap, expected) in [(180.0, "delta"), (180.001, "generic"), (86400.0, "generic"), (86400.001, "silent")] {
            for identity in ["synthetic-a", nil] as [String?] {
                var tracker = QuotaUpdateTracker()
                _ = record(sample(100, remaining: 80, identity: identity), into: &tracker)
                let event = record(sample(100 + gap, remaining: 50, identity: identity), into: &tracker)
                if expected == "silent" { XCTAssertNil(event.changedWindow()) }
                else if expected == "generic" { assertGeneric(event, reason: .stale) }
                else if identity == nil { assertGeneric(event, reason: .identityUnavailable) }
                else { XCTAssertEqual(event.changedWindow()?.change, .decreased(percentagePoints: 30)) }
            }
        }
    }

    func testTransportThenAccountFailureOrSourceChangeCannotRetainObservation() {
        for failure in [MeterError.signedOut, .unsupportedAccount, .noQuota, .serverError(-32603), .invalidExecutable] {
            var tracker = QuotaUpdateTracker()
            _ = record(sample(100, remaining: 80), into: &tracker)
            _ = tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 110))
            _ = tracker.recordFailure(failure, at: Date(timeIntervalSince1970: 120))
            XCTAssertNil(record(sample(130, remaining: 50), into: &tracker).changedWindow())
        }
        var tracker = QuotaUpdateTracker()
        _ = record(sample(100, remaining: 80), into: &tracker)
        _ = tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 110))
        tracker.invalidateSource()
        XCTAssertNil(record(sample(130, remaining: 50), into: &tracker).changedWindow())
    }

    func testRecoveryUnchangedNoBaselineOrKnownAccountBoundaryStaysSilent() {
        for (initial, oldIdentity, newIdentity, remaining) in [
            (false, "synthetic-a", "synthetic-a", 50.0),
            (true, "synthetic-a", "synthetic-a", 80.0),
            (true, "synthetic-a", "synthetic-b", 50.0),
            (true, nil, "synthetic-a", 50.0),
            (true, "synthetic-a", nil, 50.0)
        ] as [(Bool, String?, String?, Double)] {
            var tracker = QuotaUpdateTracker()
            if initial { _ = record(sample(100, remaining: 80, identity: oldIdentity), into: &tracker) }
            _ = tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 110))
            XCTAssertNil(record(sample(500, remaining: remaining, identity: newIdentity), into: &tracker).changedWindow())
        }
    }

    func testRecoveredRolloverIsGenericAndDueResetIsSilent() {
        for identity in ["synthetic-a", nil] as [String?] {
            var tracker = QuotaUpdateTracker()
            _ = record(sample(100, remaining: 20, identity: identity, reset: 200), into: &tracker)
            _ = tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 170))
            assertGeneric(record(sample(300, remaining: 90, identity: identity, reset: 1000), into: &tracker), reason: .previousReadFailed)
            _ = tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 350))
            XCTAssertNil(record(sample(1000, remaining: 10, identity: identity, reset: 1000), into: &tracker).changedWindow())
        }
    }

    func testRetainedObservationCannotAcceptStaleCurrentOrReplay() {
        for (fetched, now) in [(99.0, 120.0), (100.0, 120.0), (150.0, 331.0), (150.0, 140.0)] {
            var tracker = QuotaUpdateTracker()
            _ = record(sample(100, remaining: 80), into: &tracker)
            _ = tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 110))
            let event = tracker.record(sample(fetched, remaining: 50), at: Date(timeIntervalSince1970: now))
            XCTAssertNil(event.changedWindow())
            XCTAssertNil(event.previousFetchedAt)
        }
    }
    func testDeliveryInvalidationDistinguishesNoEventFromAccountOrWindowBoundary() {
        for identity in ["synthetic-a", nil] as [String?] {
            for reset in [200_000.0, nil] as [Double?] {
                var tracker = QuotaUpdateTracker()
                _ = record(sample(100, remaining: 80, identity: identity, reset: reset), into: &tracker)
                let unchanged = record(sample(160, remaining: 80, identity: identity, reset: reset), into: &tracker)
                XCTAssertNil(unchanged.changedWindow())
                XCTAssertFalse(unchanged.invalidatesPreviousNotices)
                let changed = record(sample(220, remaining: 50, identity: identity, reset: reset), into: &tracker)
                XCTAssertNotNil(changed.changedWindow())
                XCTAssertFalse(changed.invalidatesPreviousNotices)
                XCTAssertTrue(tracker.recordFailure(.timedOut, at: Date(timeIntervalSince1970: 230)).invalidatesPreviousNotices)
            }
        }
        for next in [sample(160, remaining: 80, identity: "synthetic-b"),
                     sample(160, remaining: 80, identity: nil),
                     sample(160, remaining: 80, reset: nil),
                     sample(160, remaining: 80, reset: 160)] {
            var tracker = QuotaUpdateTracker()
            _ = record(sample(100, remaining: 80), into: &tracker)
            XCTAssertTrue(record(next, into: &tracker).invalidatesPreviousNotices)
        }
    }

}
