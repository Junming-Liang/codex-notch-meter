import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Newline-delimited app-server protocol; only explicitly allowlisted requests exist.
public enum ReadOnlyRequest: String, CaseIterable, Sendable {
    case initialize, account = "account/read", rateLimits = "account/rateLimits/read"
    public func encoded(id: Int, backgroundPoll: Bool = true) throws -> Data {
        var object: [String: Any] = ["id": id, "method": rawValue]
        switch self {
        case .initialize:
            object["params"] = ["clientInfo": ["name": "codex_notch_meter", "title": "Codex Notch Meter", "version": "1.1.4"]]
        case .account: object["params"] = ["refreshToken": false]
        case .rateLimits:
            if backgroundPoll { object["params"] = ["excludeResetCreditDetails": true] }
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}

public struct LineFramer: Sendable {
    private var buffer = Data()
    public let maximumBytes: Int
    public init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<end])
            guard line.count <= maximumBytes else { throw MeterError.protocolLimit }
            if !line.isEmpty { lines.append(line) }
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= maximumBytes else { throw MeterError.protocolLimit }
        return lines
    }
}

public enum RPCMessage {
    case response(id: Int, result: Data)
    case failure(id: Int, code: Int)
    case serverRequest(id: Any)
    case notification

    public static func parse(_ line: Data) throws -> RPCMessage {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw MeterError.malformedResponse }
        if object["method"] is String {
            return object["id"].map { .serverRequest(id: $0) } ?? .notification
        }
        // Our request IDs are integers. Unknown response IDs are ignored by the connection.
        guard let id = object["id"] as? Int else { return .notification }
        if let error = object["error"] as? [String: Any] { return .failure(id: id, code: error["code"] as? Int ?? -32603) }
        guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else { throw MeterError.malformedResponse }
        return .response(id: id, result: try JSONSerialization.data(withJSONObject: result))
    }
}

/// Every read owns one short-lived subprocess. No shell, credential parsing or model calls.
public final class RPCConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.codexnotchmeter.rpc")
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var framer = LineFramer()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 0
    private var closed = false
    private var started = false
    private var receivedBytes = 0
    private var shutdownFinished = false
    private var shutdownMonitoring = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let totalTimeout: TimeInterval

    public init(executable: URL, arguments: [String] = ["app-server"], timeout: TimeInterval = 20, totalTimeout: TimeInterval = 45) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
        self.totalTimeout = totalTimeout
    }
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !started, !closed else { continuation.resume(throwing: MeterError.disconnected); return }
                started = true
                // One budget spans initialize, account, quota and any compatibility fallback.
                queue.asyncAfter(deadline: .now() + totalTimeout) { [weak self] in
                    guard let self, !self.closed else { return }
                    self.closeLocked(error: .timedOut)
                }
                process.executableURL = executable
                process.arguments = arguments
                process.environment = CodexExecutable.runtimeEnvironment()
                // Inherit the runtime environment, including a user's existing CODEX_HOME.
                // Use a neutral cwd so a checked-out project is never selected by the meter.
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice // Never log account/provider output.
                #if canImport(Darwin)
                // Keep a concurrently exiting child from delivering SIGPIPE to the UI process.
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    closeLocked(error: .launchFailed)
                    continuation.resume(throwing: MeterError.launchFailed)
                    return
                }
                #endif
                let readDescriptor = output.fileHandleForReading.fileDescriptor
                let readFlags = fcntl(readDescriptor, F_GETFL)
                guard readFlags != -1, fcntl(readDescriptor, F_SETFL, readFlags | O_NONBLOCK) != -1 else {
                    closeLocked(error: .launchFailed)
                    continuation.resume(throwing: MeterError.launchFailed)
                    return
                }
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    // Backpressure plus serialization prevents reads racing with handle closure.
                    self.queue.sync {
                        guard !self.closed else { return }
                        var buffer = [UInt8](repeating: 0, count: 65_536)
                        var count = -1
                        repeat {
                            count = buffer.withUnsafeMutableBytes { raw in
                                #if canImport(Darwin)
                                Darwin.read(handle.fileDescriptor, raw.baseAddress, raw.count)
                                #elseif canImport(Glibc)
                                Glibc.read(handle.fileDescriptor, raw.baseAddress, raw.count)
                                #endif
                            }
                        } while count < 0 && errno == EINTR
                        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                        guard count >= 0 else { self.closeLocked(error: .disconnected); return }
                        // One nonblocking POSIX read never waits to fill a 64 KiB buffer.
                        self.receive(Data(buffer.prefix(count)))
                    }
                }
                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.closeLocked(error: .disconnected) }
                }
                do { try process.run(); continuation.resume() }
                catch { closeLocked(error: .launchFailed); continuation.resume(throwing: MeterError.launchFailed) }
            }
        }
    }
    public func request(_ method: ReadOnlyRequest, backgroundPoll: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                queue.async { [self] in
                    guard started, !closed else { continuation.resume(throwing: MeterError.disconnected); return }
                    nextID += 1
                    let id = nextID
                    pending[id] = continuation
                    do { try input.fileHandleForWriting.write(contentsOf: method.encoded(id: id, backgroundPoll: backgroundPoll)) }
                    catch { closeLocked(error: .disconnected); return }
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        guard let self, self.pending[id] != nil else { return }
                        self.closeLocked(error: .timedOut)
                    }
                }
            }
        }, onCancel: { self.close(error: .cancelled) })
    }
    public func initialized() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed else { continuation.resume(throwing: MeterError.disconnected); return }
                do {
                    try input.fileHandleForWriting.write(contentsOf: Data("{\"method\":\"initialized\",\"params\":{}}\n".utf8))
                    continuation.resume()
                } catch { closeLocked(error: .disconnected); continuation.resume(throwing: MeterError.disconnected) }
            }
        }
    }
    public func close(error: MeterError = .cancelled) { queue.async { self.closeLocked(error: error) } }
    /// Returns only after Foundation confirms the owned child has exited.
    /// Cancellation does not skip cleanup; callers may safely await this while cancelled.
    public func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeLocked(error: .cancelled)
                if shutdownFinished || !process.isRunning { continuation.resume(); return }
                shutdownWaiters.append(continuation)
                if !shutdownMonitoring { shutdownMonitoring = true; observeShutdownLocked() }
            }
        }
    }
    private func observeShutdownLocked() {
        guard !shutdownFinished else { return }
        if !process.isRunning { finishShutdownLocked(); return }
        queue.asyncAfter(deadline: .now() + 0.05) { self.observeShutdownLocked() }
    }
    private func finishShutdownLocked() {
        shutdownFinished = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for continuation in waiters { continuation.resume() }
    }
    private func receive(_ bytes: Data) {
        guard !closed else { return }
        guard !bytes.isEmpty else { closeLocked(error: .disconnected); return }
        receivedBytes += bytes.count
        guard receivedBytes <= 4_194_304 else { closeLocked(error: .protocolLimit); return }
        do {
            for line in try framer.append(bytes) {
                switch try RPCMessage.parse(line) {
                case .response(let id, let result): pending.removeValue(forKey: id)?.resume(returning: result)
                case .failure(let id, let code): pending.removeValue(forKey: id)?.resume(throwing: code == -32601 ? MeterError.incompatibleVersion : MeterError.serverError(code))
                case .notification: break
                case .serverRequest:
                    // No auth/approval callbacks are supported. Close rather than writing a
                    // potentially unbounded response to a server that is not reading stdin.
                    closeLocked(error: .incompatibleVersion)
                    return
                }
            }
        } catch let error as MeterError { closeLocked(error: error) }
        catch { closeLocked(error: .malformedResponse) }
    }
    private func closeLocked(error: MeterError) {
        guard !closed else { return }
        closed = true
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        let waiting = Array(pending.values)
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
        if process.isRunning {
            process.terminate()
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                // Foundation tracks this exact child. Never kill by name or enumerate peers.
                if process.isRunning {
                    #if canImport(Darwin) || canImport(Glibc)
                    _ = kill(process.processIdentifier, SIGKILL)
                    #endif
                }
                if !process.isRunning { finishShutdownLocked() }
            }
        } else { finishShutdownLocked() }
    }
    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }
}
