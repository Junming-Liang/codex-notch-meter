import XCTest
@testable import NotchCore

final class QuotaUpdateTests: XCTestCase {
    private let account = "synthetic-account-a"
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func window(id: String = "codex:primary", used: Double? = 20,
                        minutes: Int? = 300, reset: Double? = 1_000) -> QuotaWindow {
        QuotaWindow(id: id, usedPercent: used, durationMinutes: minutes, resetsAt: reset.map(date))
    }
    private func snapshot(at fetched: Double, identity: String? = "synthetic-account-a",
                          bucketID: String = "codex", windows: [QuotaWindow]? = nil) -> QuotaSnapshot {
        QuotaSnapshot(buckets: [QuotaBucket(id: bucketID, name: "Synthetic quota", windows: windows ?? [window()])],
                      fetchedAt: date(fetched), continuityIdentity: QuotaContinuityIdentity(identity))
    }
    private func change(_ first: QuotaSnapshot, _ second: QuotaSnapshot, now: Double? = nil) -> QuotaWindowUpdate.Change? {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(first, at: first.fetchedAt)
        return tracker.record(second, at: now.map(date) ?? second.fetchedAt).windows.first?.change
    }
    private func parsed(identityJSON: String?, at fetched: Double, used: Double = 20) throws -> QuotaSnapshot {
        let identityField = identityJSON.map { ",\"accountId\":\($0)" } ?? ""
        let json = "{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":\(used),\"windowDurationMins\":300,\"resetsAt\":1000}}\(identityField)}"
        return try QuotaParser.parse(Data(json.utf8), fetchedAt: date(fetched))
    }

    func testInitialSnapshotHasNoConsumption() {
        var tracker = QuotaUpdateTracker()
        let event = tracker.record(snapshot(at: 100), at: date(100))
        XCTAssertEqual(event.kind, .updated)
        XCTAssertEqual(event.windows.first?.change, .updated(reason: .initial))
    }

    func testDecreaseReportsAbsolutePercentagePointsNotRelativePercent() {
        // Remaining 80 -> 60 means 20 percentage points, not 25 percent.
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40)])),
                       .decreased(percentagePoints: 20))
    }

    func testFractionalPercentagePointsRemainPrecise() {
        let first = snapshot(at: 100, windows: [window(used: 40.125)])
        let second = snapshot(at: 110, windows: [window(used: 40.375)])
        XCTAssertEqual(change(first, second), .decreased(percentagePoints: 0.25))
    }

    func testExhaustionIsStillARealDecrease() {
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 100)])),
                       .decreased(percentagePoints: 80))
    }

    func testOnlyComparableRefreshesExposeTheirSourceInterval() {
        var tracker = QuotaUpdateTracker()
        let initial = tracker.record(snapshot(at: 100), at: date(101))
        XCTAssertEqual(initial.observedAt, date(101))
        XCTAssertEqual(initial.fetchedAt, date(100))
        XCTAssertNil(initial.previousFetchedAt)
        let decrease = tracker.record(snapshot(at: 110, windows: [window(used: 40)]), at: date(112))
        XCTAssertEqual(decrease.observedAt, date(112))
        XCTAssertEqual(decrease.fetchedAt, date(110))
        XCTAssertEqual(decrease.previousFetchedAt, date(100))
        let changedAccount = tracker.record(snapshot(at: 120, identity: "synthetic-account-b"), at: date(120))
        XCTAssertNil(changedAccount.previousFetchedAt)
    }

    func testNoChangeIsNonnumericAndClassifiedUnchanged() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        let event = tracker.record(snapshot(at: 110), at: date(110))
        XCTAssertEqual(event.kind, .unchanged)
        XCTAssertEqual(event.windows.first?.change, .unchanged)
    }

    func testIncreaseNeverClaimsConsumptionOrRestoration() {
        XCTAssertEqual(change(snapshot(at: 100, windows: [window(used: 50)]), snapshot(at: 110)),
                       .updated(reason: .increased))
    }

    func testInitialAndRepeatedMissingIdentityAreIncomparable() {
        var tracker = QuotaUpdateTracker()
        XCTAssertEqual(tracker.record(snapshot(at: 100, identity: nil), at: date(100)).windows.first?.change,
                       .updated(reason: .identityUnavailable))
        XCTAssertEqual(tracker.record(snapshot(at: 110, identity: nil, windows: [window(used: 40)]), at: date(110)).windows.first?.change,
                       .updated(reason: .identityUnavailable))
    }

    func testMissingIdentityCannotBridgeAnIdentifiedPair() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        _ = tracker.record(snapshot(at: 110, identity: nil, windows: [window(used: 30)]), at: date(110))
        let recovery = tracker.record(snapshot(at: 120, windows: [window(used: 40)]), at: date(120))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .identityUnavailable))
        let next = tracker.record(snapshot(at: 130, windows: [window(used: 45)]), at: date(130))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
    }

    func testAccountSwitchStartsANewContinuityBaseline() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        let switched = tracker.record(snapshot(at: 110, identity: "synthetic-account-b", windows: [window(used: 40)]), at: date(110))
        XCTAssertEqual(switched.windows.first?.change, .updated(reason: .accountChanged))
        let next = tracker.record(snapshot(at: 120, identity: "synthetic-account-b", windows: [window(used: 45)]), at: date(120))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
    }

    func testChangedBucketOrWindowRoleCannotBeComparedByPosition() {
        let first = snapshot(at: 100)
        XCTAssertEqual(change(first, snapshot(at: 110, bucketID: "another", windows: [window(used: 40)])),
                       .updated(reason: .newWindow))
        XCTAssertEqual(change(first, snapshot(at: 110, windows: [window(id: "codex:secondary", used: 40)])),
                       .updated(reason: .newWindow))
    }

    func testChangedPositiveDurationIsNonnumeric() {
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40, minutes: 60)])),
                       .updated(reason: .durationChanged))
    }

    func testChangedFutureResetEpochIsNonnumeric() {
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40, reset: 1_001)])),
                       .updated(reason: .resetChanged))
    }

    func testExpiredOrExactlyDueResetDoesNotRestoreQuotaOrClaimConsumption() {
        for reset in [109.0, 110.0] {
            XCTAssertEqual(change(snapshot(at: 100, windows: [window(reset: reset)]),
                                  snapshot(at: 110, windows: [window(used: 40, reset: reset)])),
                           .updated(reason: .resetPending))
        }
        // Old reset is due even if the new response reports a new future epoch.
        XCTAssertEqual(change(snapshot(at: 100, windows: [window(reset: 105)]),
                              snapshot(at: 110, windows: [window(used: 40, reset: 2_000)])),
                       .updated(reason: .resetPending))
    }

    func testMissingOrInvalidMeasurementMetadataCannotProduceDelta() {
        let unknowns = [window(used: nil), window(used: -1), window(used: 101), window(used: .nan),
                        window(minutes: nil), window(minutes: 0), window(minutes: -1),
                        window(reset: nil), window(reset: .infinity), window(reset: .nan)]
        for unknown in unknowns {
            XCTAssertEqual(change(snapshot(at: 100, windows: [unknown]), snapshot(at: 110, windows: [window(used: 40)])),
                           .updated(reason: .dataUnavailable))
            XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 110, windows: [unknown])),
                           .updated(reason: .dataUnavailable))
        }
    }

    func testFreshnessBoundaryIsInclusiveAt180Seconds() {
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 280, windows: [window(used: 40)])),
                       .decreased(percentagePoints: 20))
    }

    func testLongGapAndStaleEitherSampleAreNonnumeric() {
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 281, windows: [window(used: 40)])),
                       .updated(reason: .stale))
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 200, windows: [window(used: 40)]), now: 281),
                       .updated(reason: .stale))
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40)]), now: 291),
                       .updated(reason: .stale))
    }

    func testNonMonotonicOrDuplicateFetchTimeIsNonnumeric() {
        for fetched in [99.0, 100.0] {
            XCTAssertEqual(change(snapshot(at: 100), snapshot(at: fetched, windows: [window(used: 40)]), now: 110),
                           .updated(reason: .nonMonotonic))
        }
    }

    func testFutureAndNonfiniteTimesCannotProduceDelta() {
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 120, windows: [window(used: 40)]), now: 110),
                       .updated(reason: .stale))
        for fetched in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(change(snapshot(at: 100), snapshot(at: fetched, windows: [window(used: 40)]), now: 110),
                           .updated(reason: .stale))
        }
        XCTAssertEqual(change(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40)]), now: .nan),
                       .updated(reason: .stale))
    }

    func testOutOfOrderResponseCannotMakeNextRefreshReplayConsumption() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        _ = tracker.record(snapshot(at: 110, windows: [window(used: 30)]), at: date(110))
        let replay = tracker.record(snapshot(at: 105, windows: [window(used: 25)]), at: date(115))
        XCTAssertEqual(replay.windows.first?.change, .updated(reason: .nonMonotonic))
        let recovery = tracker.record(snapshot(at: 120, windows: [window(used: 40)]), at: date(120))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .nonMonotonic))
        let next = tracker.record(snapshot(at: 130, windows: [window(used: 45)]), at: date(130))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
    }

    func testInvalidCurrentTimeClearsTheBaseline() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        _ = tracker.record(snapshot(at: 110, windows: [window(used: 30)]), at: date(291))
        let recovery = tracker.record(snapshot(at: 300, windows: [window(used: 40)]), at: date(300))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .stale))
        let next = tracker.record(snapshot(at: 310, windows: [window(used: 45)]), at: date(310))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
    }

    func testFreshSnapshotAfterLongGapBecomesNewBaseline() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        XCTAssertEqual(tracker.record(snapshot(at: 300, windows: [window(used: 40)]), at: date(300)).windows.first?.change,
                       .updated(reason: .stale))
        XCTAssertEqual(tracker.record(snapshot(at: 310, windows: [window(used: 45)]), at: date(310)).windows.first?.change,
                       .decreased(percentagePoints: 5))
    }

    func testFailedReadInvalidatesBaselineAndHasNoWindowDelta() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        let failed = tracker.recordFailure(at: date(105))
        XCTAssertEqual(failed.kind, .readFailed)
        XCTAssertTrue(failed.windows.isEmpty)
        XCTAssertEqual(failed.observedAt, date(105))
        XCTAssertNil(failed.fetchedAt)
        XCTAssertNil(failed.previousFetchedAt)
        let recovery = tracker.record(snapshot(at: 110, windows: [window(used: 40)]), at: date(110))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .previousReadFailed))
        let next = tracker.record(snapshot(at: 120, windows: [window(used: 45)]), at: date(120))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
    }

    func testSourcePathChangeInvalidatesBaseline() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        tracker.invalidateSource()
        let next = tracker.record(snapshot(at: 110, windows: [window(used: 40)]), at: date(110))
        XCTAssertEqual(next.windows.first?.change, .updated(reason: .sourceChanged))
    }

    func testEveryReturnedWindowIsTrackedAcrossReordering() {
        let firstBuckets = [
            QuotaBucket(id: "codex", name: "Codex", windows: [window(), window(id: "codex:secondary", used: 30, minutes: 10_080)]),
            QuotaBucket(id: "other", name: "Other", windows: [window(id: "other:primary", used: 40)])
        ]
        let nextBuckets = [
            QuotaBucket(id: "other", name: "Other", windows: [window(id: "other:primary", used: 44)]),
            QuotaBucket(id: "codex", name: "Codex", windows: [window(id: "codex:secondary", used: 32, minutes: 10_080), window(used: 21)])
        ]
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(QuotaSnapshot(buckets: firstBuckets, fetchedAt: date(100), continuityIdentity: QuotaContinuityIdentity(account)), at: date(100))
        let event = tracker.record(QuotaSnapshot(buckets: nextBuckets, fetchedAt: date(110), continuityIdentity: QuotaContinuityIdentity(account)), at: date(110))
        XCTAssertEqual(event.windows.count, 3)
        XCTAssertEqual(event.window(bucketID: "codex", windowID: "codex:primary")?.change, .decreased(percentagePoints: 1))
        XCTAssertEqual(event.window(bucketID: "codex", windowID: "codex:secondary")?.change, .decreased(percentagePoints: 2))
        XCTAssertEqual(event.window(bucketID: "other", windowID: "other:primary")?.change, .decreased(percentagePoints: 4))
        XCTAssertNil(event.window(bucketID: "missing", windowID: "codex:primary"))
    }

    func testMissingWindowIsNotRememberedAcrossLaterRefreshes() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100, windows: [window(), window(id: "codex:secondary", used: 30)]), at: date(100))
        let removed = tracker.record(snapshot(at: 110), at: date(110))
        XCTAssertEqual(removed.kind, .updated)
        XCTAssertEqual(removed.windows.count, 1)
        let returned = tracker.record(snapshot(at: 120, windows: [window(), window(id: "codex:secondary", used: 50)]), at: date(120))
        XCTAssertEqual(returned.window(bucketID: "codex", windowID: "codex:secondary")?.change, .updated(reason: .newWindow))
    }

    func testDuplicateOrEmptyWindowAndBucketIDsAreIncomparable() {
        let valid = snapshot(at: 100)
        let duplicates = snapshot(at: 110, windows: [window(used: 30), window(used: 40)])
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(valid, at: date(100))
        XCTAssertTrue(tracker.record(duplicates, at: date(110)).windows.allSatisfy { $0.change == .updated(reason: .dataUnavailable) })
        XCTAssertEqual(tracker.record(snapshot(at: 120, windows: [window(used: 45)]), at: date(120)).windows.first?.change,
                       .updated(reason: .dataUnavailable))
        XCTAssertEqual(change(valid, snapshot(at: 110, bucketID: "", windows: [window(used: 40)])), .updated(reason: .dataUnavailable))
        XCTAssertEqual(change(valid, snapshot(at: 110, windows: [window(id: "", used: 40)])), .updated(reason: .dataUnavailable))
        let bucket = QuotaBucket(id: "codex", name: "Codex", windows: [window(used: 40)])
        let repeatedBucket = QuotaSnapshot(buckets: [bucket, bucket], fetchedAt: date(110), continuityIdentity: QuotaContinuityIdentity(account))
        XCTAssertEqual(change(valid, repeatedBucket), .updated(reason: .dataUnavailable))
    }

    func testPublicSnapshotInitializerRemainsIdentityFree() {
        let first = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Demo", windows: [window()])], fetchedAt: date(100))
        let next = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Demo", windows: [window(used: 40)])], fetchedAt: date(110))
        XCTAssertEqual(change(first, next), .updated(reason: .identityUnavailable))
    }

    func testParserAcceptsOptionalCamelCaseIdentityForExistingResponse() throws {
        let first = try parsed(identityJSON: #""synthetic-parser-account""#, at: 100)
        let next = try parsed(identityJSON: #""synthetic-parser-account""#, at: 110, used: 40)
        XCTAssertEqual(change(first, next), .decreased(percentagePoints: 20))
        let other = try parsed(identityJSON: #""synthetic-other-account""#, at: 110, used: 40)
        XCTAssertEqual(change(first, other), .updated(reason: .accountChanged))
    }

    func testParserMissingEmptyAndMalformedIdentityStillReadsQuota() throws {
        let invalid: [String?] = [nil, "null", "false", "42", "[]", "{}", #""""#, #""   ""#, #""bad\nidentity""#]
        for identity in invalid {
            let first = try parsed(identityJSON: identity, at: 100)
            let next = try parsed(identityJSON: identity, at: 110, used: 40)
            XCTAssertEqual(next.bucket()?.windows.first?.remainingPercent, 60)
            XCTAssertEqual(change(first, next), .updated(reason: .identityUnavailable))
        }
    }

    func testParserDoesNotInferIdentityFromOtherFieldsOrNestedAccountID() throws {
        let first = try parsed(identityJSON: nil, at: 100)
        let json = #"{"account_id":"synthetic-account-a","email":"synthetic@example.invalid","rateLimits":{"accountId":"synthetic-account-a","limitId":"codex","primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1000}}}"#
        let next = try QuotaParser.parse(Data(json.utf8), fetchedAt: date(110))
        XCTAssertEqual(change(first, next), .updated(reason: .identityUnavailable))
    }

    func testParserIdentityAlsoWorksWithMultiBucketResponse() throws {
        let json = #"{"accountId":"synthetic-multi-account","rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1000}},"other":{"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":2000}}}}"#
        let first = try QuotaParser.parse(Data(json.utf8), fetchedAt: date(100))
        let next = try QuotaParser.parse(Data(json.replacingOccurrences(of: "20,", with: "25,").utf8), fetchedAt: date(110))
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(first, at: date(100))
        let event = tracker.record(next, at: date(110))
        XCTAssertEqual(event.windows.count, 2)
        XCTAssertEqual(event.window(bucketID: "codex", windowID: "codex:primary")?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(event.window(bucketID: "other", windowID: "other:secondary")?.change, .unchanged)
    }

    func testEventsAndAccidentalDiagnosticsDoNotExposePrivateContinuityIdentity() throws {
        let privateValue = "synthetic-private-continuity-sentinel"
        let first = try parsed(identityJSON: "\"\(privateValue)\"", at: 100)
        let next = try parsed(identityJSON: "\"\(privateValue)\"", at: 110, used: 40)
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(first, at: date(100))
        let event = tracker.record(next, at: date(110))
        XCTAssertFalse(String(describing: event).contains(privateValue))
        XCTAssertFalse(String(reflecting: event).contains(privateValue))
        XCTAssertFalse(String(reflecting: next).contains(privateValue))
        XCTAssertFalse(String(reflecting: tracker).contains(privateValue))
        var diagnostic = ""
        dump(next, to: &diagnostic)
        XCTAssertFalse(diagnostic.contains(privateValue))
        XCTAssertEqual(Set(Mirror(reflecting: event).children.compactMap(\.label)), Set(["kind", "windows", "observedAt", "fetchedAt", "previousFetchedAt"]))
    }
}
