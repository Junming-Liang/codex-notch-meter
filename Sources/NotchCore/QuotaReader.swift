import Foundation

private final class ResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<URL, Error>?
    private var continuation: CheckedContinuation<URL, Error>?
    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil
    }
    func finish(_ value: Result<URL, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(with: value)
    }
    func install(_ pending: CheckedContinuation<URL, Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); pending.resume(with: result); return false }
        continuation = pending; lock.unlock(); return true
    }
}

public enum CodexExecutable {
    // Cold deep verification of the official desktop artifact measured 13.03s.
    // Leave bounded headroom for slower storage; caller cancellation stays immediate.
    static let discoveryTimeout: TimeInterval = 30
    private static let resolutionQueue = DispatchQueue(label: "org.codexnotchmeter.executable-discovery", qos: .utility)
    /// A canceled/slow read-only resolver cannot keep Quit waiting or later start Codex.
    public static func resolveInstalled(override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> URL {
        try await boundedResolution { try resolve(override: override, environment: environment) }
    }
    static func boundedResolution(timeout: TimeInterval = CodexExecutable.discoveryTimeout,
        operation: @escaping @Sendable () throws -> URL) async throws -> URL {
        let gate = ResolutionGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                resolutionQueue.async {
                    guard gate.isPending else { return }
                    gate.finish(Result { try operation() })
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    gate.finish(.failure(MeterError.timedOut))
                }
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }

    public static func runtimeEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        result["PATH"] = candidates.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        return result
    }

    public static func resolve(override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        try resolveCandidates(override: override, environment: environment, desktop: DesktopCodexDiscovery.installed)
    }
    static func resolveCandidates(override: String?, environment: [String: String], desktop: () -> URL?) throws -> URL {
        if let override, !override.isEmpty {
            guard override.hasPrefix("/") else { throw MeterError.invalidExecutable }
            let selected = URL(fileURLWithPath: override)
            if selected.pathExtension == "app" {
                #if os(macOS)
                guard let helper = DesktopCodexDiscovery.helper(in: selected, verify: { DesktopCodexDiscovery.verifySignature($0, application: $1) }) else { throw MeterError.invalidExecutable }
                return helper
                #else
                throw MeterError.invalidExecutable
                #endif
            }
            guard DesktopCodexDiscovery.isRegularExecutable(selected) else { throw MeterError.invalidExecutable }
            return selected.resolvingSymlinksInPath()
        }
        if let desktop = desktop() { return desktop }
        let supplied = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // Finder's PATH is often minimal. Only probe known executable directories, never a shell.
        let directories = supplied + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let path = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("codex")
            if DesktopCodexDiscovery.isRegularExecutable(path) { return path.resolvingSymlinksInPath() }
        }
        throw MeterError.codexMissing
    }
}

public enum QuotaReader {
    /// Old helpers may reject the optional background-poll parameter. Retry only
    /// that explicit protocol error, once, within the connection's total budget.
    static func readRateLimits(_ connection: RPCConnection) async throws -> Data {
        do { return try await connection.request(.rateLimits) }
        catch MeterError.serverError(-32602) {
            try Task.checkCancellation()
            return try await connection.request(.rateLimits, backgroundPoll: false)
        }
    }

    public static func fetch(executable: URL) async throws -> QuotaSnapshot {
        let connection = RPCConnection(executable: executable)
        do {
            try await connection.start()
            _ = try await connection.request(.initialize)
            try await connection.initialized()
            let accountResponse = try await connection.request(.account)
            let account = try QuotaParser.account(accountResponse)
            switch account {
            case .signedOut: throw MeterError.signedOut
            case .unsupported: throw MeterError.unsupportedAccount
            case .chatGPT: break
            }
            let response = try await readRateLimits(connection)
            let snapshot = try QuotaParser.parse(response)
            await connection.shutdown()
            return snapshot
        } catch {
            await connection.shutdown()
            throw error
        }
    }
}
