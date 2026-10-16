import XCTest
@testable import NotchCore

final class QuotaReliabilityTests: XCTestCase {
    func testBackgroundPollOptionAndLegacyFallbackAreReadOnly() throws {
        let standard = try XCTUnwrap(JSONSerialization.jsonObject(with: ReadOnlyRequest.rateLimits.encoded(id: 3)) as? [String: Any])
        XCTAssertEqual((standard["params"] as? [String: Bool])?["excludeResetCreditDetails"], true)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: ReadOnlyRequest.rateLimits.encoded(id: 4, backgroundPoll: false)) as? [String: Any])
        XCTAssertNil(legacy["params"])
        XCTAssertEqual(legacy["method"] as? String, "account/rateLimits/read")
        XCTAssertEqual(Set(ReadOnlyRequest.allCases.map(\.rawValue)), ["initialize", "account/read", "account/rateLimits/read"])
    }

    func testTransientRecoveryDoesNotUseAuthenticationBackoff() {
        var policy = RefreshPolicy()
        for expected in [15.0, 30, 60, 120, 300, 300] {
            policy.failed(.timedOut)
            XCTAssertEqual(policy.delay, expected)
        }
        policy.failed(.signedOut)
        XCTAssertEqual(policy.delay, 120)
        policy.failed(.signedOut)
        XCTAssertEqual(policy.delay, 240)
        policy.failed(.disconnected)
        XCTAssertEqual(policy.delay, 15)
        policy.succeeded()
        XCTAssertEqual(policy.delay, 60)
    }

    func testOnlyInvalidParamsFallsBackOnce() async throws {
        // Synthetic local protocol peer. It never executes Codex or reads user files.
        let script = #"""
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"id":1,"error":{"code":-32602}}'
          else
            case "$line" in
              *excludeResetCreditDetails*) printf '%s\n' '{"id":2,"error":{"code":-32602}}';;
              *) printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25}}}}';;
            esac
          fi
        done
        """#
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1)
        try await connection.start()
        do {
            let response = try await QuotaReader.readRateLimits(connection)
            XCTAssertEqual(try QuotaParser.parse(response).bucket()?.windows.first?.remainingPercent, 75)
        } catch { await connection.shutdown(); throw error }
        await connection.shutdown()
    }

    func testOtherServerErrorsNeverFallback() async throws {
        for code in [-32603, -32000, 401, 403] {
            let script = "IFS= read -r line; printf '%s\\n' '{\"id\":1,\"error\":{\"code\":\(code)}}'; while IFS= read -r line; do printf '%s\\n' '{\"id\":2,\"result\":{}}'; done"
            let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1)
            try await connection.start()
            do { _ = try await QuotaReader.readRateLimits(connection); XCTFail("Must preserve original error") }
            catch { XCTAssertEqual(error as? MeterError, .serverError(code)) }
            await connection.shutdown()
        }
    }

    func testRepeatedInvalidParamsDoesNotLoop() async throws {
        let script = #"count=0; while IFS= read -r line; do count=$((count + 1)); printf '{"id":%s,"error":{"code":-32602}}\n' "$count"; done"#
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1, totalTimeout: 2)
        try await connection.start()
        do { _ = try await QuotaReader.readRateLimits(connection); XCTFail("Must fail after one fallback") }
        catch { XCTAssertEqual(error as? MeterError, .serverError(-32602)) }
        await connection.shutdown()
    }

    func testTotalBudgetSpansSeveralIndividuallyTimelyRequests() async throws {
        let script = #"count=0; while IFS= read -r line; do count=$((count + 1)); sleep 0.08; printf '{"id":%s,"result":{}}\n' "$count"; done"#
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1, totalTimeout: 0.2)
        try await connection.start()
        do {
            for _ in 0..<10 { _ = try await connection.request(.rateLimits) }
            XCTFail("Total deadline must stop the sequence")
        } catch { XCTAssertEqual(error as? MeterError, .timedOut) }
        await connection.shutdown()
    }

    func testCancellationDuringCompatibilityFallbackStillCleansUp() async throws {
        let script = #"IFS= read -r line; printf '%s\n' '{"id":1,"error":{"code":-32602}}'; while IFS= read -r line; do :; done"#
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 5)
        try await connection.start()
        let task = Task { try await QuotaReader.readRateLimits(connection) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error as? MeterError == .cancelled) }
        await connection.shutdown()
    }
}
