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
    private func update(_ first: QuotaSnapshot, _ second: QuotaSnapshot, now: Double? = nil) -> QuotaUpdate {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(first, at: first.fetchedAt)
        return tracker.record(second, at: now.map(date) ?? second.fetchedAt)
    }
    private func change(_ first: QuotaSnapshot, _ second: QuotaSnapshot, now: Double? = nil) -> QuotaWindowUpdate.Change? {
        update(first, second, now: now).windows.first?.change
    }
    private func assertSilent(_ event: QuotaUpdate, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(event.windows.allSatisfy { !$0.hasNumericChange }, file: file, line: line)
        XCTAssertNil(event.changedWindow(), file: file, line: line)
        XCTAssertNil(event.changedWindow(preferredBucketID: "codex", preferredWindowID: "codex:primary"), file: file, line: line)
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
        assertSilent(event)
    }

    func testDecreaseReportsAbsolutePercentagePointsNotRelativePercent() {
        // Remaining 80 -> 60 means 20 percentage points, not 25 percent.
        let event = update(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40)]))
        XCTAssertEqual(event.windows.first?.change, .decreased(percentagePoints: 20))
        XCTAssertEqual(event.windows.first?.hasNumericChange, true)
        XCTAssertEqual(event.changedWindow()?.windowID, "codex:primary")
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
        assertSilent(event)
    }

    func testIncreaseNeverClaimsConsumptionOrRestoration() {
        let event = update(snapshot(at: 100, windows: [window(used: 50)]), snapshot(at: 110))
        XCTAssertEqual(event.windows.first?.change, .updated(reason: .increased))
        XCTAssertEqual(event.windows.first?.hasNumericChange, true)
        XCTAssertNil(event.previousFetchedAt)
    }

    func testInitialMissingIdentityIsSilentAndLaterChangeIsGeneric() {
        var tracker = QuotaUpdateTracker()
        let first = tracker.record(snapshot(at: 100, identity: nil), at: date(100))
        XCTAssertEqual(first.windows.first?.change, .updated(reason: .identityUnavailable))
        assertSilent(first)
        let next = tracker.record(snapshot(at: 110, identity: nil, windows: [window(used: 40)]), at: date(110))
        XCTAssertEqual(next.windows.first?.change, .updated(reason: .identityUnavailable))
        XCTAssertTrue(next.windows.first?.hasNumericChange == true)
        XCTAssertNil(next.previousFetchedAt)
    }

    func testMissingIdentityCannotBridgeAnIdentifiedPair() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        _ = tracker.record(snapshot(at: 110, identity: nil, windows: [window(used: 30)]), at: date(110))
        let recovery = tracker.record(snapshot(at: 120, windows: [window(used: 40)]), at: date(120))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .identityUnavailable))
        assertSilent(recovery)
        let next = tracker.record(snapshot(at: 130, windows: [window(used: 45)]), at: date(130))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(next.windows.first?.hasNumericChange, true)
    }

    func testAccountSwitchStartsANewContinuityBaseline() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        let switched = tracker.record(snapshot(at: 110, identity: "synthetic-account-b", windows: [window(used: 40)]), at: date(110))
        XCTAssertEqual(switched.windows.first?.change, .updated(reason: .accountChanged))
        assertSilent(switched)
        let next = tracker.record(snapshot(at: 120, identity: "synthetic-account-b", windows: [window(used: 45)]), at: date(120))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(next.windows.first?.hasNumericChange, true)
    }

    func testChangedBucketOrWindowRoleCannotBeComparedByPosition() {
        let first = snapshot(at: 100)
        XCTAssertEqual(change(first, snapshot(at: 110, bucketID: "another", windows: [window(used: 40)])),
                       .updated(reason: .newWindow))
        XCTAssertEqual(change(first, snapshot(at: 110, windows: [window(id: "codex:secondary", used: 40)])),
                       .updated(reason: .newWindow))
    }

    func testChangedPositiveDurationIsNonnumeric() {
        let event = update(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40, minutes: 60)]))
        XCTAssertEqual(event.windows.first?.change, .updated(reason: .durationChanged))
        assertSilent(event)
    }

    func testChangedFutureResetWithNumericChangeIsEligibleButNeverConsumption() {
        for used in [10.0, 40.0] {
            let event = update(snapshot(at: 100), snapshot(at: 110, windows: [window(used: used, reset: 1_001)]))
            XCTAssertEqual(event.windows.first?.change, .updated(reason: .resetChanged))
            XCTAssertEqual(event.windows.first?.hasNumericChange, true)
            XCTAssertEqual(event.changedWindow()?.windowID, "codex:primary")
            XCTAssertNil(event.previousFetchedAt)
        }
    }

    func testResetMetadataChangeWithoutNumericChangeIsSilent() {
        for oldReset in [105.0, 110.0, 1_000.0] {
            let event = update(snapshot(at: 100, windows: [window(reset: oldReset)]),
                               snapshot(at: 110, windows: [window(reset: 2_000)]))
            XCTAssertEqual(event.windows.first?.change, .updated(reason: .resetChanged))
            assertSilent(event)
        }
    }

    func testExpiredOrExactlyDueResetDoesNotRestoreQuotaOrClaimConsumption() {
        for reset in [109.0, 110.0] {
            let event = update(snapshot(at: 100, windows: [window(reset: reset)]),
                               snapshot(at: 110, windows: [window(used: 40, reset: reset)]))
            XCTAssertEqual(event.windows.first?.change, .updated(reason: .resetPending))
            assertSilent(event)
        }
    }

    func testNewFutureResetAfterOldCycleExpiresCanReportANumericChange() {
        for oldReset in [99.0, 105.0, 110.0] {
            for used in [0.0, 40.0] {
                let event = update(snapshot(at: 100, windows: [window(reset: oldReset)]),
                                   snapshot(at: 110, windows: [window(used: used, reset: 2_000)]))
                XCTAssertEqual(event.windows.first?.change, .updated(reason: .resetChanged))
                XCTAssertEqual(event.windows.first?.hasNumericChange, true)
                XCTAssertNil(event.previousFetchedAt)
            }
        }
    }

    func testChangedResetThatIsNotFutureRemainsSilent() {
        for reset in [99.0, 110.0] {
            let event = update(snapshot(at: 100), snapshot(at: 110, windows: [window(used: 40, reset: reset)]))
            XCTAssertEqual(event.windows.first?.change, .updated(reason: .resetPending))
            assertSilent(event)
        }
    }

    func testMissingOrInvalidMeasurementMetadataCannotProduceDelta() {
        let unknowns = [window(used: nil), window(used: -1), window(used: 101), window(used: .nan),
                        window(minutes: nil), window(minutes: 0), window(minutes: -1),
                        window(reset: nil), window(reset: .infinity), window(reset: .nan)]
        for unknown in unknowns {
            let missingPrevious = update(snapshot(at: 100, windows: [unknown]), snapshot(at: 110, windows: [window(used: 40)]))
            XCTAssertEqual(missingPrevious.windows.first?.change, .updated(reason: .dataUnavailable))
            assertSilent(missingPrevious)
            let missingCurrent = update(snapshot(at: 100), snapshot(at: 110, windows: [unknown]))
            XCTAssertEqual(missingCurrent.windows.first?.change, .updated(reason: .dataUnavailable))
            assertSilent(missingCurrent)
        }
    }

    func testFreshnessBoundaryIsInclusiveAt180Seconds() {
        let event = update(snapshot(at: 100), snapshot(at: 280, windows: [window(used: 40)]))
        XCTAssertEqual(event.windows.first?.change, .decreased(percentagePoints: 20))
        XCTAssertEqual(event.windows.first?.hasNumericChange, true)
    }

    func testInvalidContinuityAndTimingAreNeverNumericNoticeEligible() {
        let first = snapshot(at: 100)
        let changed = [window(used: 40)]
        let cases: [(QuotaSnapshot, QuotaSnapshot, Double)] = [
            (first, snapshot(at: 110, identity: nil, windows: changed), 110),
            (snapshot(at: 100, identity: nil), snapshot(at: 110, windows: changed), 110),
            (first, snapshot(at: 110, identity: "synthetic-account-b", windows: changed), 110),
            (first, snapshot(at: 110, bucketID: "other", windows: changed), 110),
            (first, snapshot(at: 110, windows: [window(id: "codex:secondary", used: 40)]), 110),
            (first, snapshot(at: 110, windows: changed), 291),
            (first, snapshot(at: 99, windows: changed), 110),
            (first, snapshot(at: 100, windows: changed), 110),
            (first, snapshot(at: 120, windows: changed), 110),
            (first, snapshot(at: .nan, windows: changed), 110),
            (first, snapshot(at: .infinity, windows: changed), 110),
            (first, snapshot(at: -.infinity, windows: changed), 110),
            (first, snapshot(at: 110, windows: changed), .nan),
            (first, snapshot(at: 110, windows: changed), .infinity)
        ]
        for (old, new, now) in cases {
            assertSilent(update(old, new, now: now))
        }
    }

    func testUnknownNumbersCannotMakeAChangedResetEligible() {
        let unknowns: [Double?] = [nil, -1, 101, .nan, .infinity, -.infinity]
        for used in unknowns {
            let missingPrevious = update(snapshot(at: 100, windows: [window(used: used, reset: 105)]),
                                         snapshot(at: 110, windows: [window(used: 40, reset: 2_000)]))
            XCTAssertEqual(missingPrevious.windows.first?.change, .updated(reason: .resetChanged))
            assertSilent(missingPrevious)
            let missingCurrent = update(snapshot(at: 100),
                                        snapshot(at: 110, windows: [window(used: used, reset: 2_000)]))
            XCTAssertEqual(missingCurrent.windows.first?.change, .updated(reason: .resetChanged))
            assertSilent(missingCurrent)
        }
    }

    func testLongGapUsesGenericReasonAndStaleCurrentRemainsSilent() {
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
        assertSilent(replay)
        let recovery = tracker.record(snapshot(at: 120, windows: [window(used: 40)]), at: date(120))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .nonMonotonic))
        assertSilent(recovery)
        let next = tracker.record(snapshot(at: 130, windows: [window(used: 45)]), at: date(130))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(next.windows.first?.hasNumericChange, true)
    }

    func testInvalidCurrentTimeClearsTheBaseline() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        _ = tracker.record(snapshot(at: 110, windows: [window(used: 30)]), at: date(291))
        let recovery = tracker.record(snapshot(at: 300, windows: [window(used: 40)]), at: date(300))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .stale))
        assertSilent(recovery)
        let next = tracker.record(snapshot(at: 310, windows: [window(used: 45)]), at: date(310))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(next.windows.first?.hasNumericChange, true)
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
        assertSilent(failed)
        let recovery = tracker.record(snapshot(at: 110, windows: [window(used: 40)]), at: date(110))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .previousReadFailed))
        assertSilent(recovery)
        let next = tracker.record(snapshot(at: 120, windows: [window(used: 45)]), at: date(120))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(next.windows.first?.hasNumericChange, true)
    }

    func testSourcePathChangeInvalidatesBaseline() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100), at: date(100))
        tracker.invalidateSource()
        let next = tracker.record(snapshot(at: 110, windows: [window(used: 40)]), at: date(110))
        XCTAssertEqual(next.windows.first?.change, .updated(reason: .sourceChanged))
        assertSilent(next)
        let following = tracker.record(snapshot(at: 120, windows: [window(used: 45)]), at: date(120))
        XCTAssertEqual(following.windows.first?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(following.windows.first?.hasNumericChange, true)
        tracker.invalidateSource()
        let changedAgain = tracker.record(snapshot(at: 130, windows: [window(used: 50)]), at: date(130))
        XCTAssertEqual(changedAgain.windows.first?.change, .updated(reason: .sourceChanged))
        assertSilent(changedAgain)
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
        XCTAssertTrue(event.windows.allSatisfy(\.hasNumericChange))
        XCTAssertEqual(event.changedWindow()?.bucketID, "other")
        XCTAssertEqual(event.changedWindow(preferredBucketID: "codex", preferredWindowID: "codex:primary")?.windowID, "codex:primary")
    }

    func testSecondaryOnlyNumericChangeNeverSelectsUnchangedPrimary() {
        let first = snapshot(at: 100, windows: [window(), window(id: "codex:secondary", used: 30, minutes: 10_080)])
        let next = snapshot(at: 110, windows: [window(), window(id: "codex:secondary", used: 32, minutes: 10_080)])
        let event = update(first, next)
        XCTAssertEqual(event.window(bucketID: "codex", windowID: "codex:primary")?.hasNumericChange, false)
        let selected = event.changedWindow(preferredBucketID: "codex", preferredWindowID: "codex:primary")
        XCTAssertEqual(selected?.bucketID, "codex")
        XCTAssertEqual(selected?.windowID, "codex:secondary")
        XCTAssertEqual(selected?.change, .decreased(percentagePoints: 2))
        XCTAssertEqual(event.changedWindow(), selected)
    }

    func testChangedWindowSelectionUsesExactIDsAndDoesNotChangeContinuity() {
        let oldBuckets = [
            QuotaBucket(id: "codex", name: "Codex", windows: [window(id: "primary"), window(id: "secondary", used: 30)]),
            QuotaBucket(id: "other", name: "Other", windows: [window(id: "primary", used: 40)])
        ]
        let newBuckets = [
            QuotaBucket(id: "codex", name: "Codex", windows: [window(id: "primary", used: 21), window(id: "secondary", used: 32)]),
            QuotaBucket(id: "other", name: "Other", windows: [window(id: "primary", used: 43)])
        ]
        let first = QuotaSnapshot(buckets: oldBuckets, fetchedAt: date(100), continuityIdentity: QuotaContinuityIdentity(account))
        let next = QuotaSnapshot(buckets: newBuckets, fetchedAt: date(110), continuityIdentity: QuotaContinuityIdentity(account))
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(first, at: date(100))
        let event = tracker.record(next, at: date(110))
        let primary = event.window(bucketID: "codex", windowID: "primary")
        XCTAssertEqual(event.changedWindow(), primary)
        XCTAssertEqual(event.changedWindow(preferredBucketID: "codex", preferredWindowID: "secondary")?.change,
                       .decreased(percentagePoints: 2))
        let other = event.changedWindow(preferredBucketID: "other", preferredWindowID: "primary")
        XCTAssertEqual(other?.bucketID, "other")
        XCTAssertEqual(other?.change, .decreased(percentagePoints: 3))
        XCTAssertEqual(event.changedWindow(preferredBucketID: "missing", preferredWindowID: "primary"), primary)
        XCTAssertEqual(event.changedWindow(preferredBucketID: "other", preferredWindowID: "missing"), primary)
        XCTAssertEqual(event.changedWindow(preferredBucketID: nil, preferredWindowID: "primary"), primary)
        XCTAssertEqual(event.changedWindow(preferredBucketID: "other", preferredWindowID: nil), primary)
        XCTAssertEqual(event.changedWindow(preferredBucketID: "codex", preferredWindowID: "primary"), primary)

        let unchanged = QuotaSnapshot(buckets: newBuckets, fetchedAt: date(120), continuityIdentity: QuotaContinuityIdentity(account))
        assertSilent(tracker.record(unchanged, at: date(120)))
    }

    func testMetadataOnlyPreferredWindowDoesNotMaskOtherNumericChange() {
        let first = snapshot(at: 100, windows: [window(), window(id: "codex:secondary", used: 30)])
        let next = snapshot(at: 110, windows: [window(reset: 2_000), window(id: "codex:secondary", used: 31)])
        let event = update(first, next)
        XCTAssertEqual(event.window(bucketID: "codex", windowID: "codex:primary")?.change, .updated(reason: .resetChanged))
        XCTAssertEqual(event.changedWindow(preferredBucketID: "codex", preferredWindowID: "codex:primary")?.windowID, "codex:secondary")
    }

    func testSelectedNumericResetKeepsResetClassificationWhenOtherWindowIsComparable() {
        let first = snapshot(at: 100, windows: [window(), window(id: "codex:secondary", used: 30, reset: 105)])
        let next = snapshot(at: 110, windows: [window(), window(id: "codex:secondary", used: 10, reset: 2_000)])
        let event = update(first, next)
        // The unchanged primary exposes an interval for itself, never for the
        // selected secondary's new cycle.
        XCTAssertEqual(event.previousFetchedAt, date(100))
        let selected = event.changedWindow(preferredBucketID: "codex", preferredWindowID: "codex:primary")
        XCTAssertEqual(selected?.windowID, "codex:secondary")
        XCTAssertEqual(selected?.hasNumericChange, true)
        XCTAssertEqual(selected?.change, .updated(reason: .resetChanged))
    }

    func testNewResetCycleBecomesTheBaselineForTheNextConsumptionComparison() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100, windows: [window(used: 80, reset: 105)]), at: date(100))
        let reset = tracker.record(snapshot(at: 110, windows: [window(used: 10, reset: 2_000)]), at: date(110))
        XCTAssertEqual(reset.windows.first?.change, .updated(reason: .resetChanged))
        XCTAssertEqual(reset.windows.first?.hasNumericChange, true)
        let next = tracker.record(snapshot(at: 120, windows: [window(used: 15, reset: 2_000)]), at: date(120))
        XCTAssertEqual(next.windows.first?.change, .decreased(percentagePoints: 5))
        XCTAssertEqual(next.windows.first?.hasNumericChange, true)
        XCTAssertEqual(next.previousFetchedAt, date(110))
    }

    func testMissingWindowIsNotRememberedAcrossLaterRefreshes() {
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(snapshot(at: 100, windows: [window(), window(id: "codex:secondary", used: 30)]), at: date(100))
        let removed = tracker.record(snapshot(at: 110), at: date(110))
        XCTAssertEqual(removed.kind, .updated)
        XCTAssertEqual(removed.windows.count, 1)
        assertSilent(removed)
        let returned = tracker.record(snapshot(at: 120, windows: [window(), window(id: "codex:secondary", used: 50)]), at: date(120))
        XCTAssertEqual(returned.window(bucketID: "codex", windowID: "codex:secondary")?.change, .updated(reason: .newWindow))
        assertSilent(returned)
    }

    func testDuplicateOrEmptyWindowAndBucketIDsAreIncomparable() {
        let valid = snapshot(at: 100)
        let duplicates = snapshot(at: 110, windows: [window(used: 30), window(used: 40)])
        var tracker = QuotaUpdateTracker()
        _ = tracker.record(valid, at: date(100))
        let ambiguous = tracker.record(duplicates, at: date(110))
        XCTAssertTrue(ambiguous.windows.allSatisfy { $0.change == .updated(reason: .dataUnavailable) })
        assertSilent(ambiguous)
        let recovery = tracker.record(snapshot(at: 120, windows: [window(used: 45)]), at: date(120))
        XCTAssertEqual(recovery.windows.first?.change, .updated(reason: .dataUnavailable))
        assertSilent(recovery)
        XCTAssertEqual(change(valid, snapshot(at: 110, bucketID: "", windows: [window(used: 40)])), .updated(reason: .dataUnavailable))
        XCTAssertEqual(change(valid, snapshot(at: 110, windows: [window(id: "", used: 40)])), .updated(reason: .dataUnavailable))
        assertSilent(update(valid, snapshot(at: 110, bucketID: "", windows: [window(used: 40)])))
        assertSilent(update(valid, snapshot(at: 110, windows: [window(id: "", used: 40)])))
        let bucket = QuotaBucket(id: "codex", name: "Codex", windows: [window(used: 40)])
        let repeatedBucket = QuotaSnapshot(buckets: [bucket, bucket], fetchedAt: date(110), continuityIdentity: QuotaContinuityIdentity(account))
        XCTAssertEqual(change(valid, repeatedBucket), .updated(reason: .dataUnavailable))
        assertSilent(update(valid, repeatedBucket))
        assertSilent(update(repeatedBucket, snapshot(at: 120, windows: [window(used: 45)])))
    }

    func testDuplicatedBucketsWithDistinctWindowIDsAreStillIneligible() {
        let first = snapshot(at: 100, windows: [window(), window(id: "codex:secondary", used: 30)])
        let duplicated = QuotaSnapshot(buckets: [
            QuotaBucket(id: "codex", name: "First", windows: [window(used: 21)]),
            QuotaBucket(id: "codex", name: "Second", windows: [window(id: "codex:secondary", used: 32)])
        ], fetchedAt: date(110), continuityIdentity: QuotaContinuityIdentity(account))
        let event = update(first, duplicated)
        XCTAssertTrue(event.windows.allSatisfy { $0.change == .updated(reason: .dataUnavailable) })
        assertSilent(event)
        assertSilent(update(duplicated, snapshot(at: 120, windows: [window(used: 25), window(id: "codex:secondary", used: 35)])))
    }

    func testAmbiguousPreferredWindowDoesNotHideAnUnambiguousNumericChange() {
        let first = snapshot(at: 100, windows: [window(), window(id: "codex:secondary", used: 30)])
        let next = snapshot(at: 110, windows: [window(used: 21), window(used: 22), window(id: "codex:secondary", used: 35)])
        let event = update(first, next)
        XCTAssertTrue(event.windows.filter { $0.windowID == "codex:primary" }.allSatisfy { !$0.hasNumericChange })
        XCTAssertEqual(event.changedWindow(preferredBucketID: "codex", preferredWindowID: "codex:primary")?.windowID, "codex:secondary")
        XCTAssertEqual(event.changedWindow()?.change, .decreased(percentagePoints: 5))
    }

    func testPublicSnapshotInitializerRemainsIdentityFree() {
        let first = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Demo", windows: [window()])], fetchedAt: date(100))
        let next = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Demo", windows: [window(used: 40)])], fetchedAt: date(110))
        XCTAssertEqual(change(first, next), .updated(reason: .identityUnavailable))
        XCTAssertTrue(update(first, next).windows.first?.hasNumericChange == true)
        XCTAssertNil(update(first, next).previousFetchedAt)
    }

    func testParserAcceptsOptionalCamelCaseIdentityForExistingResponse() throws {
        let first = try parsed(identityJSON: #""synthetic-parser-account""#, at: 100)
        let next = try parsed(identityJSON: #""synthetic-parser-account""#, at: 110, used: 40)
        XCTAssertEqual(change(first, next), .decreased(percentagePoints: 20))
        let other = try parsed(identityJSON: #""synthetic-other-account""#, at: 110, used: 40)
        XCTAssertEqual(change(first, other), .updated(reason: .accountChanged))
    }

    func testParserUnavailableIdentityAllowsGenericChangeButNeverConsumption() throws {
        let invalid: [String?] = [nil, "null", "false", "42", "[]", "{}", #""""#, #""   ""#, #""bad\nidentity""#]
        for identity in invalid {
            let first = try parsed(identityJSON: identity, at: 100)
            let next = try parsed(identityJSON: identity, at: 110, used: 40)
            XCTAssertEqual(next.bucket()?.windows.first?.remainingPercent, 60)
            let event = update(first, next)
            XCTAssertEqual(event.windows.first?.change, .updated(reason: .identityUnavailable))
            XCTAssertTrue(event.windows.first?.hasNumericChange == true)
            XCTAssertNil(event.previousFetchedAt)
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


    func testIdentityFreeParserSequenceInitialUnchangedDecreaseAndIncrease() throws {
        var tracker = QuotaUpdateTracker()
        for (index, used) in [20.0, 20.0, 20.125, 10.0, 10.0].enumerated() {
            let current = try parsed(identityJSON: nil, at: 100 + Double(index) * 60, used: used)
            let event = tracker.record(current, at: current.fetchedAt)
            XCTAssertEqual(event.windows.first?.change, .updated(reason: .identityUnavailable))
            XCTAssertEqual(event.windows.first?.hasNumericChange, index == 2 || index == 3)
            XCTAssertNil(event.previousFetchedAt)
        }
    }

    func testIdentityFreeSubHundredthChangeIsNotRoundedAway() throws {
        let event = update(try parsed(identityJSON: nil, at: 100, used: 20.001),
                           try parsed(identityJSON: nil, at: 110, used: 20.002))
        XCTAssertTrue(event.changedWindow()?.hasNumericChange == true)
        XCTAssertEqual(event.changedWindow()?.change, .updated(reason: .identityUnavailable))
        XCTAssertNil(event.previousFetchedAt)
    }

    func testIdentityFreeMapSelectsChangedSecondaryAcrossReorderAndPreferenceSwitch() throws {
        let firstJSON = #"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":15}},"codex":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1000},"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":2000}}}}"#
        let nextJSON = #"{"rateLimitsByLimitId":{"codex":{"secondary":{"usedPercent":30.25,"windowDurationMins":10080,"resetsAt":2000},"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1000}},"other":{"primary":{"usedPercent":15}}}}"#
        let first = try QuotaParser.parse(Data(firstJSON.utf8), fetchedAt: date(100))
        let next = try QuotaParser.parse(Data(nextJSON.utf8), fetchedAt: date(160))
        let event = update(first, next)
        for preference in ["codex:primary", "codex:secondary", "missing"] {
            XCTAssertEqual(event.changedWindow(preferredBucketID: "codex", preferredWindowID: preference)?.windowID, "codex:secondary")
        }
        XCTAssertNil(event.previousFetchedAt)
        assertSilent(update(next, try QuotaParser.parse(Data(nextJSON.utf8), fetchedAt: date(170))))
    }

    func testStableAbsentOrNullOptionalMetadataAllowsOnlyGenericCurrentValues() throws {
        for identity in [nil, #""synthetic-parser-account""#] as [String?] {
            for fields in ["", #", "windowDurationMins":null, "resetsAt":null"#,
                           #", "windowDurationMins":300"#, #", "resetsAt":1000"#] {
                let identityField = identity.map { ",\"accountId\":\($0)" } ?? ""
                func response(_ used: Double, _ time: Double) throws -> QuotaSnapshot {
                    let json = "{\"rateLimits\":{\"primary\":{\"usedPercent\":\(used)\(fields)}}\(identityField)}"
                    return try QuotaParser.parse(Data(json.utf8), fetchedAt: date(time))
                }
                let first = try response(20, 100), next = try response(40, 160)
                let event = update(first, next)
                XCTAssertEqual(event.changedWindow()?.change, .updated(reason: identity == nil ? .identityUnavailable : .dataUnavailable))
                XCTAssertNil(event.previousFetchedAt)
                assertSilent(update(next, try response(40, 170)))
            }
        }
    }

    func testMetadataFreeChangedWindowDoesNotInheritAnotherWindowsConsumptionClaim() {
        let first = snapshot(at: 100, windows: [window(minutes: nil, reset: nil),
            window(id: "codex:secondary", used: 30)])
        let next = snapshot(at: 160, windows: [window(used: 40, minutes: nil, reset: nil),
            window(id: "codex:secondary", used: 30)])
        let event = update(first, next)
        // The aggregate interval belongs to the comparable unchanged secondary.
        // A selected generic primary still has no decreased/unchanged classification.
        XCTAssertEqual(event.previousFetchedAt, date(100))
        XCTAssertEqual(event.changedWindow()?.windowID, "codex:primary")
        XCTAssertEqual(event.changedWindow()?.change, .updated(reason: .dataUnavailable))
        XCTAssertEqual(event.window(bucketID: "codex", windowID: "codex:secondary")?.change, .unchanged)
    }

    func testGenericFallbackRejectsOneSidedMetadataAndChangedDuration() {
        for identity in [nil, account] {
            let pairs: [(QuotaWindow, QuotaWindow)] = [
                (window(minutes: nil), window(used: 40)),
                (window(), window(used: 40, minutes: nil)),
                (window(reset: nil), window(used: 40)),
                (window(), window(used: 40, reset: nil)),
                (window(minutes: 300, reset: nil), window(used: 40, minutes: 60, reset: nil))
            ]
            for (old, new) in pairs {
                assertSilent(update(snapshot(at: 100, identity: identity, windows: [old]),
                                    snapshot(at: 160, identity: identity, windows: [new])))
            }
        }
    }

    func testIdentityFreeResetChangeNeedsNumericDifferenceAndFutureReset() {
        let first = snapshot(at: 100, identity: nil, windows: [window(reset: 105)])
        for used in [0.0, 40.0] {
            let event = update(first, snapshot(at: 160, identity: nil, windows: [window(used: used, reset: 2000)]))
            XCTAssertEqual(event.changedWindow()?.change, .updated(reason: .identityUnavailable))
            XCTAssertNil(event.previousFetchedAt)
        }
        for (used, reset) in [(20.0, 2000.0), (40.0, 105.0), (40.0, 160.0)] {
            assertSilent(update(first, snapshot(at: 160, identity: nil, windows: [window(used: used, reset: reset)])))
        }
    }

    func testIdentityFreeFallbackNeverAcceptsStaleReplayedOrFutureReads() {
        for identity in [nil, account] {
            let first = snapshot(at: 100, identity: identity, windows: [window(minutes: nil, reset: nil)])
            for (fetched, now) in [(99.0, 110.0), (100.0, 110.0), (120.0, 110.0),
                                   (160.0, 341.0), (Double.nan, 160.0),
                                   (Double.infinity, 160.0), (160.0, Double.nan)] {
                let next = snapshot(at: fetched, identity: identity, windows: [window(used: 40, minutes: nil, reset: nil)])
                assertSilent(update(first, next, now: now))
            }
        }
    }

    func testIdentityFreeFailureAndSourceChangeRebaselineBeforeNotification() {
        for invalidateSource in [false, true] {
            var tracker = QuotaUpdateTracker()
            _ = tracker.record(snapshot(at: 100, identity: nil), at: date(100))
            if invalidateSource { tracker.invalidateSource() }
            else { assertSilent(tracker.recordFailure(at: date(120))) }
            assertSilent(tracker.record(snapshot(at: 160, identity: nil, windows: [window(used: 40)]), at: date(160)))
            let next = tracker.record(snapshot(at: 170, identity: nil, windows: [window(used: 41)]), at: date(170))
            XCTAssertEqual(next.changedWindow()?.change, .updated(reason: .identityUnavailable))
            XCTAssertNil(next.previousFetchedAt)
        }
    }

    func testIdentityFreeUnknownValuesAndAmbiguousWindowsStaySilent() {
        for unknown in [nil, -1, 101, Double.nan, Double.infinity] as [Double?] {
            let old = snapshot(at: 100, identity: nil, windows: [window(used: unknown)])
            let new = snapshot(at: 160, identity: nil, windows: [window(used: 40)])
            assertSilent(update(old, new)); assertSilent(update(new, snapshot(at: 170, identity: nil, windows: [window(used: unknown)])))
        }
        let duplicated = snapshot(at: 160, identity: nil, windows: [window(used: 40), window(used: 41)])
        assertSilent(update(snapshot(at: 100, identity: nil), duplicated))
        assertSilent(update(duplicated, snapshot(at: 170, identity: nil, windows: [window(used: 42)])))
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
        let fields = Mirror(reflecting: event).children
        XCTAssertEqual(Set(fields.compactMap(\.label)),
                       Set(["kind", "windows", "observedAt", "fetchedAt", "previousFetchedAt", "invalidatesPreviousNotices"]))
        XCTAssertEqual(fields.first { $0.label == "invalidatesPreviousNotices" }?.value as? Bool, false)
        XCTAssertEqual(event.windows.first?.hasNumericChange, true)
        XCTAssertFalse(String(reflecting: event.changedWindow()).contains(privateValue))
        XCTAssertEqual(Set(Mirror(reflecting: try XCTUnwrap(event.changedWindow())).children.compactMap(\.label)),
                       Set(["bucketID", "windowID", "change", "hasNumericChange"]))
    }
}
