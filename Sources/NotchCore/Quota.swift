import Foundation

public struct QuotaWindow: Equatable, Identifiable, Sendable {
    public let id: String
    public let usedPercent: Double?
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(id: String, usedPercent: Double?, durationMinutes: Int?, resetsAt: Date?) {
        self.id = id
        self.usedPercent = usedPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        self.durationMinutes = durationMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.resetsAt = resetsAt
    }
    public var remainingPercent: Double? { usedPercent.map { 100 - $0 } }
    public var label: String {
        guard let minutes = durationMinutes else { return "Window duration unavailable" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }
    public func resetPending(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public func countdown(at now: Date) -> String {
        guard let reset = resetsAt else { return "Reset time unavailable" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset due · awaiting fresh data" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}

public struct QuotaBucket: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let windows: [QuotaWindow]
    public init(id: String, name: String, windows: [QuotaWindow]) {
        self.id = id; self.name = name; self.windows = windows
    }
}

// In-memory continuity only. This deliberately has no raw-value accessor or encoding.
// Redacted descriptions/reflection keep accidental snapshot diagnostics from exposing it.
struct QuotaContinuityIdentity: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String
    init?(_ value: String?) {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        self.value = value
    }
    var description: String { "<opaque quota continuity>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

public struct QuotaSnapshot: Equatable, Sendable {
    public let buckets: [QuotaBucket]
    public let fetchedAt: Date
    let continuityIdentity: QuotaContinuityIdentity?
    public init(buckets: [QuotaBucket], fetchedAt: Date) {
        self.init(buckets: buckets, fetchedAt: fetchedAt, continuityIdentity: nil)
    }
    init(buckets: [QuotaBucket], fetchedAt: Date, continuityIdentity: QuotaContinuityIdentity?) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.continuityIdentity = continuityIdentity
    }
    public func bucket(preferredID: String? = nil) -> QuotaBucket? {
        if let preferredID, let selected = buckets.first(where: { $0.id == preferredID }) { return selected }
        return buckets.first(where: { $0.id == "codex" }) ?? buckets.first
    }
    public func isStale(at now: Date, threshold: TimeInterval = 180) -> Bool {
        now.timeIntervalSince(fetchedAt) > threshold
    }
}

public enum MeterError: Error, Equatable, LocalizedError, Sendable {
    case codexMissing, invalidExecutable, signedOut, unsupportedAccount, noQuota, malformedResponse
    case incompatibleVersion, timedOut, disconnected, protocolLimit, launchFailed, cancelled
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .codexMissing: return "No supported Codex desktop helper or CLI was found. Choose the installed official application or CLI in Settings."
        case .invalidExecutable: return "The selected application/helper could not be verified or is unavailable. Choose an installed official Codex application or CLI."
        case .signedOut: return "Sign in to Codex with your ChatGPT account, then refresh."
        case .unsupportedAccount: return "This account type does not provide ChatGPT quota windows. API-key billing is not supported."
        case .noQuota: return "Codex did not return quota windows. No allowance has been assumed."
        case .malformedResponse: return "Codex returned an unrecognized response. Try updating the official CLI."
        case .incompatibleVersion: return "This Codex version does not support the required account interface. Update the official CLI."
        case .timedOut: return "Codex did not respond in time. Check your connection, then refresh."
        case .disconnected: return "The Codex account connection ended. Refresh to try again."
        case .protocolLimit: return "The Codex response exceeded the safety limit."
        case .launchFailed: return "The installed Codex CLI could not be started. Check the executable in Settings."
        case .cancelled: return "Refresh cancelled."
        case .serverError(let code): return "Codex could not read quotas (error \(code)). Check your connection or sign-in, then refresh."
        }
    }
}

public enum AccountState: Equatable, Sendable { case chatGPT, signedOut, unsupported }

public enum QuotaParser {
    // Lossy optional fields tolerate evolving versions while keeping missing data unknown.
    private struct WindowDTO: Decodable {
        let used: Double?, minutes: Int?, reset: Double?
        enum CodingKeys: String, CodingKey { case usedPercent, windowDurationMins, resetsAt }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            used = try? c.decode(Double.self, forKey: .usedPercent)
            minutes = try? c.decode(Int.self, forKey: .windowDurationMins)
            reset = try? c.decode(Double.self, forKey: .resetsAt)
        }
        func value(id: String) -> QuotaWindow {
            let date = reset.flatMap { value -> Date? in
                guard value.isFinite, value > 0, value < 253402300800 else { return nil }
                return Date(timeIntervalSince1970: value)
            }
            return QuotaWindow(id: id, usedPercent: used, durationMinutes: minutes, resetsAt: date)
        }
    }
    private struct BucketDTO: Decodable {
        let limitID: String?, name: String?, primary: WindowDTO?, secondary: WindowDTO?
        enum CodingKeys: String, CodingKey { case limitId, limitName, primary, secondary }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limitID = try? c.decode(String.self, forKey: .limitId)
            name = try? c.decode(String.self, forKey: .limitName)
            primary = try? c.decode(WindowDTO.self, forKey: .primary)
            secondary = try? c.decode(WindowDTO.self, forKey: .secondary)
        }
        func value(key: String) -> QuotaBucket {
            let id = key.isEmpty ? (limitID ?? "codex") : key
            let windows = [("primary", primary), ("secondary", secondary)].compactMap { role, dto in dto?.value(id: "\(id):\(role)") }
            // Labels derive from returned duration, never from primary/secondary position.
            return QuotaBucket(id: id, name: name?.isEmpty == false ? name! : id, windows: windows)
        }
    }
    private struct BucketMap: Decodable {
        let values: [String: BucketDTO]
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var parsed: [String: BucketDTO] = [:]
            for key in container.allKeys {
                if let bucket = try? container.decode(BucketDTO.self, forKey: key) { parsed[key.stringValue] = bucket }
            }
            values = parsed
        }
    }
    private struct ResponseDTO: Decodable {
        let buckets: [String: BucketDTO]?, legacy: BucketDTO?
        let continuityIdentity: QuotaContinuityIdentity?
        enum CodingKeys: String, CodingKey { case rateLimitsByLimitId, rateLimits, accountId }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            buckets = (try? c.decode(BucketMap.self, forKey: .rateLimitsByLimitId))?.values
            legacy = try? c.decode(BucketDTO.self, forKey: .rateLimits)
            // Optional on older helpers; never infer identity from account type or quota values.
            continuityIdentity = QuotaContinuityIdentity(try? c.decode(String.self, forKey: .accountId))
        }
    }
    public static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        guard let dto = try? JSONDecoder().decode(ResponseDTO.self, from: data) else { throw MeterError.malformedResponse }
        let buckets: [QuotaBucket]
        if let multi = dto.buckets, !multi.isEmpty {
            buckets = multi.keys.sorted().compactMap { key in multi[key]?.value(key: key) }
        } else if let legacy = dto.legacy { buckets = [legacy.value(key: "")] }
        else { throw MeterError.noQuota }
        guard buckets.contains(where: { !$0.windows.isEmpty }) else { throw MeterError.noQuota }
        return QuotaSnapshot(buckets: buckets, fetchedAt: fetchedAt, continuityIdentity: dto.continuityIdentity)
    }
    public static func account(_ data: Data) throws -> AccountState {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value.keys.contains("account") else { throw MeterError.malformedResponse }
        if value["account"] is NSNull { return .signedOut }
        guard let account = value["account"] as? [String: Any], let type = account["type"] as? String else { throw MeterError.malformedResponse }
        return type == "chatgpt" ? .chatGPT : .unsupported
    }
}
