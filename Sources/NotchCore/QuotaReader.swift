import Foundation

public enum CodexExecutable {
    public static func runtimeEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        result["PATH"] = candidates.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        return result
    }

    public static func resolve(override: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            guard override.hasPrefix("/"), fm.isExecutableFile(atPath: override) else { throw MeterError.invalidExecutable }
            return URL(fileURLWithPath: override)
        }
        let supplied = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // Finder's PATH is often minimal. Only probe known executable directories, never a shell.
        let directories = supplied + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let path = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("codex")
            if fm.isExecutableFile(atPath: path.path) { return path }
        }
        throw MeterError.codexMissing
    }
}

public enum QuotaReader {
    public static func fetch(executable: URL) async throws -> QuotaSnapshot {
        let connection = RPCConnection(executable: executable)
        defer { connection.close() }
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
        let response = try await connection.request(.rateLimits)
        return try QuotaParser.parse(response)
    }
}
