import XCTest
@testable import NotchCore

final class RPCTests: XCTestCase {
    func testOnlyReadOnlyMethodsCanBeEncoded() throws {
        XCTAssertEqual(Set(ReadOnlyRequest.allCases.map(\.rawValue)), ["initialize", "account/read", "account/rateLimits/read"])
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: ReadOnlyRequest.account.encoded(id: 2)) as? [String: Any])
        let params = try XCTUnwrap(account["params"] as? [String: Any])
        XCTAssertEqual(params["refreshToken"] as? Bool, false)
    }
    func testFramerHandlesFragmentsAndSeveralLines() throws {
        var framer = LineFramer()
        XCTAssertTrue(try framer.append(Data("{\"id\":".utf8)).isEmpty)
        let lines = try framer.append(Data("1}\n\n{\"id\":2}\n{\"id\":".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"id\":1}", "{\"id\":2}"])
        XCTAssertEqual(try framer.append(Data("3}\n".utf8)).count, 1)
    }
    func testOversizedLineRejectedWithOrWithoutTerminator() {
        for suffix in ["", "\n"] {
            var framer = LineFramer(maximumBytes: 3)
            XCTAssertThrowsError(try framer.append(Data(("1234" + suffix).utf8))) { XCTAssertEqual($0 as? MeterError, .protocolLimit) }
        }
    }
    func testErrorDoesNotExposeUpstreamMessage() throws {
        let result = try RPCMessage.parse(Data(#"{"id":4,"error":{"code":-32601,"message":"synthetic private content"}}"#.utf8))
        guard case .failure(let id, let code) = result else { return XCTFail("Expected error") }
        XCTAssertEqual(id, 4); XCTAssertEqual(code, -32601)
    }
    func testServerRequestIsDistinguishedFromNotification() throws {
        if case .serverRequest = try RPCMessage.parse(Data(#"{"id":1,"method":"approval/request"}"#.utf8)) {} else { XCTFail("Expected request") }
        if case .notification = try RPCMessage.parse(Data(#"{"method":"account/updated"}"#.utf8)) {} else { XCTFail("Expected notification") }
    }
    func testRuntimeEnvironmentPreservesCodexHomeAndAddsNodePaths() {
        let environment = CodexExecutable.runtimeEnvironment(["PATH": "/usr/bin:/bin", "CODEX_HOME": "/synthetic/custom-home"])
        XCTAssertEqual(environment["CODEX_HOME"], "/synthetic/custom-home")
        XCTAssertTrue(environment["PATH"]?.contains("/opt/homebrew/bin") ?? false)
        XCTAssertTrue(environment["PATH"]?.contains("/usr/local/bin") ?? false)
    }
    func testUnexpectedServerRequestClosesReadOnlyConnection() async throws {
        let script = #"IFS= read -r line; printf '%s\n' '{"id":99,"method":"synthetic/auth/callback"}'; while IFS= read -r line; do :; done"#
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 1)
        defer { connection.close() }
        try await connection.start()
        do { _ = try await connection.request(.initialize); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? MeterError, .incompatibleVersion) }
    }
    func testExecutableOverrideMustBeAbsoluteAndExecutable() {
        XCTAssertThrowsError(try CodexExecutable.resolve(override: "./codex", environment: [:]))
        XCTAssertThrowsError(try CodexExecutable.resolve(override: "/a/nonexistent/codex", environment: [:]))
    }
    func testRealPipeTransportWithoutCodexOrAccount() async throws {
        // A fixed local shell fixture emits synthetic protocol objects; never invokes Codex.
        let script = #"while IFS= read -r line; do case "$line" in *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{"userAgent":"synthetic"}}';; *'"method":"account/read"'*) printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}';; *'"method":"account/rateLimits/read"'*) printf '%s\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}';; esac; done"#
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 2)
        defer { connection.close() }
        try await connection.start()
        _ = try await connection.request(.initialize)
        try await connection.initialized()
        let account = try await connection.request(.account)
        XCTAssertEqual(try QuotaParser.account(account), .chatGPT)
        let quotas = try await connection.request(.rateLimits)
        XCTAssertEqual(try QuotaParser.parse(quotas).bucket()?.windows.first?.remainingPercent, 75)
    }
    func testTimeoutFailsPendingRequest() async throws {
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while IFS= read -r line; do :; done"], timeout: 0.05)
        defer { connection.close() }
        try await connection.start()
        do { _ = try await connection.request(.initialize); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? MeterError, .timedOut) }
    }
    func testEarlyExitDoesNotHang() async throws {
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], timeout: 1)
        defer { connection.close() }
        try await connection.start()
        do { _ = try await connection.request(.initialize); XCTFail("Expected disconnect") }
        catch { XCTAssertEqual(error as? MeterError, .disconnected) }
    }
    func testCancellationClosesConnection() async throws {
        let connection = RPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while IFS= read -r line; do :; done"], timeout: 10)
        try await connection.start()
        let task = Task { try await connection.request(.initialize) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || error as? MeterError == .cancelled) }
        connection.close()
    }
}
