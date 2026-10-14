import XCTest
@testable import NotchCore

final class QuotaTests: XCTestCase {
    private func parse(_ json: String) throws -> QuotaSnapshot { try QuotaParser.parse(Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 100)) }
    func testMultiBucketTakesPriorityOverLegacy() throws {
        let snapshot = try parse(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":2000000000},"secondary":{"usedPercent":46,"windowDurationMins":10080}},"other":{"primary":{"usedPercent":10,"windowDurationMins":15}}}}"#)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.bucket()?.windows.map(\.remainingPercent), [72, 54])
        XCTAssertEqual(snapshot.bucket()?.windows.map(\.label), ["5-hour window", "7-day window"])
        XCTAssertEqual(snapshot.bucket(preferredID: "other")?.windows.first?.label, "15-minute window")
    }
    func testMalformedSiblingDoesNotDiscardValidBucket() throws {
        let snapshot = try parse(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25}},"unknown_future_bucket":false},"rateLimits":{"primary":{"usedPercent":99}}}"#)
        XCTAssertEqual(snapshot.bucket()?.windows.first?.remainingPercent, 75)
    }
    func testLegacyAndMissingFields() throws {
        let snapshot = try parse(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0},"secondary":{}}}"#)
        XCTAssertEqual(snapshot.bucket()?.windows[0].remainingPercent, 100)
        XCTAssertNil(snapshot.bucket()?.windows[1].remainingPercent)
        XCTAssertNil(snapshot.bucket()?.windows[0].resetsAt)
        XCTAssertEqual(snapshot.bucket()?.windows[0].label, "Window duration unavailable")
    }
    func testUnknownNeverBecomesFull() throws {
        for value in ["null", "-2", "101", "true", "\"25\""] {
            let snapshot = try parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":\(value)}}}")
            XCTAssertNil(snapshot.bucket()?.windows.first?.remainingPercent)
        }
    }
    func testNoQuotaAndMalformed() {
        for value in [#"{}"#, #"{"rateLimits":null}"#, #"{"rateLimits":{"primary":null,"secondary":null}}"#] {
            XCTAssertThrowsError(try parse(value)) { XCTAssertEqual($0 as? MeterError, .noQuota) }
        }
        XCTAssertThrowsError(try parse("not json")) { XCTAssertEqual($0 as? MeterError, .malformedResponse) }
    }
    func testEmptyMultiBucketFallsBack() throws {
        let snapshot = try parse(#"{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":75}}}"#)
        XCTAssertEqual(snapshot.bucket()?.windows.first?.remainingPercent, 25)
    }
    func testDurationNotAssumedFromOrder() throws {
        let snapshot = try parse(#"{"rateLimits":{"primary":{"windowDurationMins":10080},"secondary":{"windowDurationMins":60}}}"#)
        XCTAssertEqual(snapshot.bucket()?.windows.map(\.label), ["7-day window", "1-hour window"])
    }
    func testResetIsInformationalNeverRestoresQuota() {
        let window = QuotaWindow(id: "a", usedPercent: 100, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(window.countdown(at: Date(timeIntervalSince1970: 99)), "Resets in 1m")
        XCTAssertTrue(window.resetPending(at: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(window.countdown(at: Date(timeIntervalSince1970: 101)), "Reset due · awaiting fresh data")
        XCTAssertEqual(window.remainingPercent, 0)
    }
    func testStaleThreshold() {
        let snapshot = QuotaSnapshot(buckets: [], fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(snapshot.isStale(at: Date(timeIntervalSince1970: 280)))
        XCTAssertTrue(snapshot.isStale(at: Date(timeIntervalSince1970: 281)))
    }
    func testAccountModesIgnoreIdentity() throws {
        XCTAssertEqual(try QuotaParser.account(Data(#"{"account":{"type":"chatgpt","email":"synthetic@example.invalid"}}"#.utf8)), .chatGPT)
        XCTAssertEqual(try QuotaParser.account(Data(#"{"account":null}"#.utf8)), .signedOut)
        XCTAssertEqual(try QuotaParser.account(Data(#"{"account":{"type":"apiKey"}}"#.utf8)), .unsupported)
        XCTAssertEqual(try QuotaParser.account(Data(#"{"account":{"type":"amazonBedrock"}}"#.utf8)), .unsupported)
        XCTAssertThrowsError(try QuotaParser.account(Data(#"{"unexpected":true}"#.utf8)))
    }
    func testInvalidDurationAndResetStayUnknown() throws {
        let snapshot = try parse(#"{"rateLimits":{"primary":{"windowDurationMins":-1,"resetsAt":-1}}}"#)
        XCTAssertNil(snapshot.bucket()?.windows.first?.durationMinutes)
        XCTAssertNil(snapshot.bucket()?.windows.first?.resetsAt)
    }
}
