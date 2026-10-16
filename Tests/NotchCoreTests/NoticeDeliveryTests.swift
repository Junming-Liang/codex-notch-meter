import XCTest
@testable import NotchCore

final class NoticeDeliveryTests: XCTestCase {
    private struct Notice: Identifiable, Equatable {
        let id: Int
        let remaining: Double
    }
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func enqueue(_ queue: inout NoticeDeliveryQueue<Notice>, id: Int = 1,
                         received: Double = 100, fetched: Double = 100, reset: Double? = 1_000) {
        queue.enqueue(Notice(id: id, remaining: Double(80 - id)), receivedAt: date(received),
            fetchedAt: date(fetched), resetsAt: reset.map(date))
    }

    func testSuppressionForElevenSecondsPreservesFreshNoticeUntilOneDelivery() {
        var queue = NoticeDeliveryQueue<Notice>()
        enqueue(&queue)
        XCTAssertNil(queue.candidate(at: date(100), blocked: true))
        XCTAssertNil(queue.candidate(at: date(111), blocked: true))
        XCTAssertTrue(queue.isPending)
        XCTAssertEqual(queue.candidate(at: date(111), blocked: false)?.id, 1)
        // A temporarily absent panel does not consume the event.
        XCTAssertEqual(queue.candidate(at: date(112), blocked: false)?.id, 1)
        queue.didDeliver()
        XCTAssertNil(queue.candidate(at: date(112), blocked: false))
        enqueue(&queue, received: 112, fetched: 112)
        XCTAssertFalse(queue.isPending, "duplicate publication cannot redeliver the same event")
    }

    func testNewestChangeCoalescesAndSameIDCannotRenewFreshness() {
        var queue = NoticeDeliveryQueue<Notice>()
        enqueue(&queue)
        enqueue(&queue, received: 200, fetched: 200)
        XCTAssertNil(queue.candidate(at: date(280.001), blocked: false))
        enqueue(&queue, id: 2, received: 281, fetched: 281)
        enqueue(&queue, id: 3, received: 282, fetched: 282)
        XCTAssertEqual(queue.candidate(at: date(283), blocked: false)?.id, 3)
        queue.invalidate()
        XCTAssertFalse(queue.isPending)
        enqueue(&queue, id: 3, received: 284, fetched: 284)
        XCTAssertFalse(queue.isPending, "late duplicate cannot revive invalidated data")
        enqueue(&queue, id: 4, received: 285, fetched: 285)
        XCTAssertEqual(queue.candidate(at: date(285), blocked: false)?.id, 4)
    }

    func testExactFreshnessBoundaryAndBothOriginalTimestampsAreRequired() {
        let cases: [(Double, Double, Double, Bool)] = [
            (100.0, 100.0, 280.0, true), (100, 100, 280.001, false),
            (110, 100, 280.001, false), (100, 110, 280.001, false),
            (101, 100, 100, false), (100, 101, 100, false)
        ]
        for (received, fetched, now, expected) in cases {
            var queue = NoticeDeliveryQueue<Notice>()
            enqueue(&queue, received: received, fetched: fetched)
            XCTAssertEqual(queue.candidate(at: date(now), blocked: false) != nil, expected)
        }
    }

    func testInvalidDatesAndDueResetExpireEvenWhileSuppressed() {
        let cases: [(Double, Double, Double, Double)] = [
            (Double.nan, 100.0, 1_000.0, 110.0), (100, .infinity, 1_000, 110),
            (100, 100, .nan, 110), (100, 100, 1_000, .nan),
            (100, 100, 110, 110), (100, 100, 109, 110), (100, 100, 1_000, 281)
        ]
        for (received, fetched, reset, now) in cases {
            var queue = NoticeDeliveryQueue<Notice>()
            enqueue(&queue, received: received, fetched: fetched, reset: reset)
            XCTAssertNil(queue.candidate(at: date(now), blocked: true))
            XCTAssertFalse(queue.isPending)
            XCTAssertNil(queue.candidate(at: date(105), blocked: false), "expired entry cannot revive after clock rollback")
        }
        var queue = NoticeDeliveryQueue<Notice>()
        enqueue(&queue, reset: nil)
        XCTAssertNotNil(queue.candidate(at: date(111), blocked: false), "optional reset absence does not disable generic notices")
    }

    func testExplicitInvalidationClearsPendingBeforeFreshReplacement() {
        var queue = NoticeDeliveryQueue<Notice>()
        enqueue(&queue)
        queue.invalidate()
        XCTAssertNil(queue.candidate(at: date(111), blocked: false))
        enqueue(&queue, id: 2, received: 112, fetched: 112)
        XCTAssertEqual(queue.candidate(at: date(112), blocked: false)?.id, 2)
    }
}
