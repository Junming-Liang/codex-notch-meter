import XCTest
@testable import NotchCore

final class DebugCaptureTests: XCTestCase {
    private let metadata = DebugCapture.Metadata(version: "1.1.3", build: "14")
    private func objects(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }
    func testDisabledDoesNotReadClockEvaluatePayloadOrWrite() throws {
        var reads = 0, evaluations = 0, writes = 0
        let capture = DebugCapture(clock: { reads += 1; return 0 })
        func payload() -> [DebugCapture.Field: Double] { evaluations += 1; return [.progress: 1] }
        for _ in 0..<1000 { capture.record(.hover, values: payload()); capture.count(.polls) }
        XCTAssertEqual(reads, 0); XCTAssertEqual(evaluations, 0); XCTAssertTrue(capture.counters.isEmpty)
        XCTAssertFalse(capture.hasCapture); XCTAssertFalse(capture.isRecording)
        XCTAssertThrowsError(try capture.export { _ in writes += 1 })
        XCTAssertEqual(writes, 0)
    }
    func testExpiryStopsAndRetainsWithoutImplicitWrite() throws {
        var now = 10.0
        let capture = DebugCapture(duration: 2, clock: { now })
        capture.start(metadata: metadata); capture.record(.gate)
        now = 12; capture.record(.input); capture.count(.polls)
        XCTAssertFalse(capture.isRecording); XCTAssertEqual(capture.stopReason, .durationLimit)
        XCTAssertEqual(capture.storedEvents, 1)
        XCTAssertNil(capture.counters[.polls])
        XCTAssertEqual(try objects(capture.exportData()).last?["stopReason"] as? String, "durationLimit")
        let oldSession = capture.sessionID
        capture.start(metadata: metadata)
        XCTAssertNotEqual(capture.sessionID, oldSession); XCTAssertEqual(capture.storedEvents, 0)
        XCTAssertTrue(capture.counters.isEmpty)
    }
    func testRingRetainsLatestEventsAndReportsEvictions() throws {
        var now = 0.0
        let capture = DebugCapture(maximumEvents: 3, clock: { now })
        capture.start(metadata: metadata)
        for i in 0..<10 { now = Double(i); capture.record(.ownership, values: [.target: Double(i)]) }
        capture.stop()
        let rows = try objects(capture.exportData()).filter { $0["event"] != nil }
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(capture.counters[.evicted], 7)
        XCTAssertEqual(rows.map { $0["sequence"] as? Int }, [8, 9, 10])
    }
    func testByteBoundAndDurationClamp() throws {
        var now = 0.0
        let capture = DebugCapture(maximumBytes: 16_384, maximumEvents: 100_000, duration: 5000, clock: { now })
        capture.start(metadata: metadata)
        for i in 0..<10_000 {
            now = Double(i) / 100
            capture.record(.frame, values: Dictionary(uniqueKeysWithValues: DebugCapture.Field.allCases.map { ($0, 1) }))
        }
        XCTAssertLessThanOrEqual(capture.storedBytes, 8192)
        XCTAssertGreaterThan(capture.counters[.evicted] ?? 0, 0)
        now = 300; XCTAssertTrue(capture.expireIfNeeded())
        XCTAssertLessThanOrEqual(try capture.exportData().count, 16_384)
    }
    func testMonotonicObservationIsNotEventOrScheduledTimestamp() throws {
        var now = 100.0
        let capture = DebugCapture(clock: { now })
        capture.start(metadata: metadata)
        now = 102
        capture.record(.input, values: [.sourceOffsetMs: capture.offsetMilliseconds(100.2)])
        now = 101.5 // injected bad/backward clock still cannot reorder rows
        capture.record(.frameCallback, values: [.scheduledOffsetMs: capture.offsetMilliseconds(102.1)])
        capture.stop()
        let rows = try objects(capture.exportData()).filter { $0["event"] != nil }
        XCTAssertEqual(rows[0]["elapsedMs"] as? Double, 2000)
        XCTAssertEqual(rows[1]["elapsedMs"] as? Double, 2000)
        XCTAssertEqual((rows[0]["values"] as? [String: Double])?["sourceOffsetMs"], 200)
        XCTAssertEqual((rows[1]["values"] as? [String: Double])?["scheduledOffsetMs"], 2100)
    }
    func testSamplingAndHardBudgetCountDroppedEventsWithoutEvaluatingPayload() throws {
        var now = 0.0, evaluated = 0
        let capture = DebugCapture(clock: { now }); capture.start(metadata: metadata)
        func payload() -> [DebugCapture.Field: Double] { evaluated += 1; return [:] }
        for _ in 0..<100 { capture.count(.polls); capture.record(.input, sampled: true, values: payload()) }
        XCTAssertEqual(evaluated, 1); XCTAssertEqual(capture.counters[.polls], 100)
        XCTAssertEqual(capture.counters[.sampledOut], 99)
        for _ in 0..<200 { capture.record(.ownership, values: payload()) }
        XCTAssertEqual(capture.storedEvents, 120); XCTAssertEqual(evaluated, 120)
        XCTAssertEqual(capture.counters[.rateLimited], 81)
        now = 1; capture.record(.ownership); XCTAssertEqual(capture.storedEvents, 121)
    }
    func testPrivacyAllowlistFixtureRejectsTextAndOutOfNeighborhoodValues() throws {
        let privateFixture = ["FAKE_TOKEN_SENTINEL", "PRIVATE_SONG_SENTINEL", "PRIVATE_LYRICS_SENTINEL", "file:///private/example"]
        let capture = DebugCapture(clock: { 0 })
        capture.start(metadata: .init(version: privateFixture.joined(separator: ":"), build: privateFixture[0]))
        capture.record(.hover, values: [.pointerX: 100_000, .pointerY: -.infinity, .anchorX: 2,
                                       .sourceAgeMs: .nan], labels: [.reason: .dwellReset])
        capture.stop(); let data = try capture.exportData(), text = String(decoding: data, as: UTF8.self)
        for sentinel in privateFixture { XCTAssertFalse(text.contains(sentinel)) }
        let rows = try objects(data), row = try XCTUnwrap(rows.first { $0["event"] != nil })
        XCTAssertEqual(Set(row.keys), ["sequence", "elapsedMs", "event", "values", "labels"])
        let values = try XCTUnwrap(row["values"] as? [String: Double])
        XCTAssertTrue(Set(values.keys).isSubset(of: Set(DebugCapture.Field.allCases.map(\.rawValue))))
        XCTAssertNil(values["pointerX"]); XCTAssertNil(values["pointerY"]); XCTAssertNil(values["sourceAgeMs"])
        XCTAssertEqual(values["anchorX"], 2); XCTAssertEqual(capture.counters[.invalidFields], 3)
        XCTAssertEqual(rows.first?["version"] as? String, "unknown")
    }
    func testIdentifiersAreBoundedAndReassignedPerSession() {
        let capture = DebugCapture(clock: { 0 }), first = UUID(), second = UUID()
        XCTAssertEqual(capture.identifier(first), 0)
        capture.start(metadata: metadata)
        XCTAssertEqual(capture.identifier(first), 1); XCTAssertEqual(capture.identifier(second), 2)
        for _ in 0..<1000 { _ = capture.identifier(UUID()) }
        XCTAssertEqual(capture.identifier(UUID()), 0); XCTAssertGreaterThan(capture.counters[.identifierOverflow] ?? 0, 0)
        capture.start(metadata: metadata); XCTAssertEqual(capture.identifier(second), 1)
    }
    func testExportRequiresStoppedCaptureAndFailurePreservesExactData() throws {
        enum Failure: Error { case disk }
        var now = 0.0, writes = 0
        let capture = DebugCapture(clock: { now }); capture.start(metadata: metadata)
        capture.record(.ownership, labels: [.owner: .details, .reason: .enter])
        XCTAssertThrowsError(try capture.export { _ in writes += 1 }); XCTAssertEqual(writes, 0)
        now = 1; capture.stop(); let before = try capture.exportData()
        XCTAssertThrowsError(try capture.export { _ in writes += 1; throw Failure.disk })
        XCTAssertEqual(writes, 1); XCTAssertEqual(try capture.exportData(), before)
        try capture.export { data in writes += 1; XCTAssertEqual(data, before) }
        XCTAssertEqual(writes, 2); XCTAssertEqual(try capture.exportData(), before)
    }
    func testFullLatestGeometrySurvivesPartialRowsAndTimelineEviction() throws {
        var now = 0.0
        let capture = DebugCapture(maximumEvents: 2, clock: { now })
        capture.start(metadata: metadata)
        let values: [DebugCapture.Field: Double] = [.screenWidth: 1512, .screenHeight: 982, .scale: 2,
            .notchWidth: 220, .notchHeight: 32, .horizontalAdjustment: 0, .widthAdjustment: 0,
            .depthAdjustment: 0, .cornerAdjustment: 0, .reducedMotion: 0]
        for island in 1...10 {
            now += 1
            capture.record(.geometry, island: Double(island), values: values)
            capture.record(.geometry, island: Double(island), values: [.progress: 0.5])
        }
        for _ in 0..<10 { now += 1; capture.record(.hover) }
        capture.stop()
        let header = try XCTUnwrap(objects(capture.exportData()).first)
        let contexts = try XCTUnwrap(header["latestGeometryContext"] as? [[String: Any]])
        XCTAssertEqual(contexts.count, 8)
        let dimensions = contexts.compactMap { $0["values"] as? [String: Double] }
        XCTAssertEqual(dimensions.compactMap { $0["island"] }, Array(3...10).map(Double.init))
        XCTAssertTrue(dimensions.allSatisfy { $0["scale"] == 2 && $0["notchWidth"] == 220 })
    }
    func testExpiryNotifiesOnceAndStoppedCallbacksCannotChangeSession() {
        var now = 0.0, stopped = 0
        let capture = DebugCapture(duration: 1, clock: { now })
        capture.didStop = { stopped += 1 }
        capture.start(metadata: metadata); now = 1; capture.count(.polls)
        XCTAssertEqual(stopped, 1)
        capture.stop(); capture.record(.hover); _ = capture.expireIfNeeded()
        XCTAssertEqual(stopped, 1); XCTAssertFalse(capture.isRecording)
    }

}
