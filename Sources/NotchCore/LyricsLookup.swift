import Foundation

/// Only the four fields disclosed by the online-lookup consent UI. This value is
/// ephemeral: do not put it, request URLs, provider bodies or errors in logs.
public struct LyricsLookupTrack: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public static let maximumFieldBytes = 1_024

    public init(title: String, artist: String, album: String, duration: TimeInterval) throws {
        self.title = try Self.validField(title)
        self.artist = try Self.validField(artist)
        self.album = try Self.validField(album)
        // LRCLIB's current public contract is 1...3600 seconds. Do not drop
        // duration or album to make an otherwise unsupported track searchable.
        guard duration.isFinite, (1...3_600).contains(duration) else {
            throw LyricsLookupError.invalidTrack
        }
        self.duration = duration
    }

    private static func validField(_ value: String) throws -> String {
        guard value.utf8.prefix(maximumFieldBytes + 1).count <= maximumFieldBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LyricsLookupError.invalidTrack
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LyricsLookupError.invalidTrack }
        return trimmed
    }
}

/// Fixed, user-safe categories. Never expose an underlying URL/NSError/body.
public enum LyricsLookupError: Error, Equatable, Sendable {
    case consentRequired, invalidTrack, requestNotAllowed, invalidResponse
    case identityMismatch, tooLarge, invalidUTF8, invalidLyrics
    case unsupportedFile, fileUnavailable, cancelled, offline, timedOut
    case transportFailure, busy
    case rateLimited(retryAfter: TimeInterval)
    case serviceUnavailable(retryAfter: TimeInterval)
}

public enum LyricsLookupResult: Equatable, Sendable {
    case matched(LyricsDocument)
    case noMatch
    /// A matching record exists but contains no usable lyrics. This does not
    /// imply that the track is instrumental.
    case unavailable
}

/// Constructed only by the consent-gated factory, never from arbitrary URLs.
public struct LyricsLookupRequest: Sendable {
    public let url: URL
    public let method: String
    public let timeout: TimeInterval
    public let maximumResponseBytes: Int
    public let userAgent: String
}

public struct LyricsLookupResponse: Sendable {
    public let url: URL
    public let statusCode: Int
    public let contentType: String?
    public let retryAfter: String?
    public let body: Data

    public init(url: URL, statusCode: Int, contentType: String? = "application/json",
                retryAfter: String? = nil, body: Data) {
        self.url = url
        self.statusCode = statusCode
        self.contentType = contentType
        self.retryAfter = retryAfter
        self.body = body
    }
}

/// A real transport must enforce the byte limit while receiving, reject ALL
/// redirects, cancel underlying work on cancellation, and enforce the deadline.
public protocol LyricsLookupTransport: Sendable {
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse
}

/// Pure request/response boundary. No file, network, timer, settings or cache use.
/// Public API reviewed 2026-10-16: https://lrclib.net/docs
/// Server matching is fuzzy; our stricter identity gate is deliberately allowed
/// to miss a valid record rather than attach another edition's lyrics.
/// The server's MIT software license is NOT a license to all lyric content.
public enum LRCLIBLookup {
    public static let maximumResponseBytes = 1_048_576
    public static let requestTimeout: TimeInterval = 10
    public static let minimumRequestGap: TimeInterval = 0.3
    public static let durationTolerance: TimeInterval = 2
    public static let userAgent = "CodexNotchMeter/1.0.0-beta.1 (https://github.com/Junming-Liang/codex-notch-meter)"

    public static func request(track: LyricsLookupTrack, consent: Bool) throws -> LyricsLookupRequest {
        guard consent else { throw LyricsLookupError.consentRequired }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(track.duration))
        ]
        // Query parsers treat a literal plus as a space; preserve song titles
        // containing + without changing any of the four disclosed fields.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, isAllowed(url: url) else {
            throw LyricsLookupError.requestNotAllowed
        }
        return LyricsLookupRequest(url: url, method: "GET", timeout: requestTimeout,
                                   maximumResponseBytes: maximumResponseBytes, userAgent: userAgent)
    }

    public static func isAllowed(url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "lrclib.net", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/api/get", let items = parts.queryItems,
              items.count == 4 else { return false }
        let names = ["track_name", "artist_name", "album_name", "duration"]
        guard Set(items.map(\.name)) == Set(names),
              let title = items.first(where: { $0.name == "track_name" })?.value,
              let artist = items.first(where: { $0.name == "artist_name" })?.value,
              let album = items.first(where: { $0.name == "album_name" })?.value,
              let durationText = items.first(where: { $0.name == "duration" })?.value,
              let duration = Double(durationText) else { return false }
        return (try? LyricsLookupTrack(title: title, artist: artist, album: album, duration: duration)) != nil
    }

    public static func decode(_ response: LyricsLookupResponse, for track: LyricsLookupTrack,
                              request: LyricsLookupRequest) throws -> LyricsLookupResult {
        guard isAllowed(url: response.url), response.url == request.url else {
            throw LyricsLookupError.requestNotAllowed
        }
        switch response.statusCode {
        case 404: return .noMatch
        case 429: throw LyricsLookupError.rateLimited(retryAfter: retryDelay(response.retryAfter))
        case 503: throw LyricsLookupError.serviceUnavailable(retryAfter: retryDelay(response.retryAfter))
        case 200: break
        default: throw LyricsLookupError.invalidResponse
        }
        guard response.body.count <= maximumResponseBytes else { throw LyricsLookupError.tooLarge }
        let mime = response.contentType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mime == "application/json" else { throw LyricsLookupError.invalidResponse }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: response.body) }
        catch { throw LyricsLookupError.invalidResponse }
        guard record.id > 0,
              let identity = try? LyricsLookupTrack(title: record.trackName, artist: record.artistName,
                                                    album: record.albumName, duration: record.duration) else {
            throw LyricsLookupError.invalidResponse
        }
        guard equal(identity.title, track.title), equal(identity.artist, track.artist),
              equal(identity.album, track.album),
              abs(identity.duration - track.duration) <= durationTolerance else {
            throw LyricsLookupError.identityMismatch
        }
        for text in [record.plainLyrics, record.syncedLyrics].compactMap({ $0 }) {
            guard text.utf8.count <= LRCParser.maximumInputBytes else { throw LyricsLookupError.tooLarge }
        }
        if record.instrumental {
            guard !hasText(record.syncedLyrics), !hasText(record.plainLyrics) else {
                throw LyricsLookupError.invalidResponse
            }
            return .matched(.instrumental)
        }
        if let synced = record.syncedLyrics, hasText(synced) {
            let document = try parse(synced, track: track)
            if case .synchronized(let cues) = document.content {
                guard cues.contains(where: { !$0.text.isEmpty }),
                      cues.allSatisfy({ $0.startTime <= track.duration + durationTolerance }) else {
                    throw LyricsLookupError.invalidLyrics
                }
                return .matched(document)
            }
            // A malformed synchronized field may fall back only to an explicit
            // plain field. Never assign inferred timing to that fallback.
            guard hasText(record.plainLyrics) else { throw LyricsLookupError.invalidLyrics }
        }
        if let plain = record.plainLyrics, hasText(plain) {
            let document = try parse(plain, track: track)
            guard case .plain = document.content else { throw LyricsLookupError.invalidLyrics }
            return .matched(document)
        }
        return .unavailable
    }

    /// Delta seconds or an HTTP date. Invalid/missing values get a conservative
    /// minute; a valid long server delay is never shortened by a local cap.
    public static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        guard let value, value.utf8.count <= 128 else { return 60 }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = Double(trimmed), seconds.isFinite {
            return max(minimumRequestGap, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: trimmed) else { return 60 }
        return max(minimumRequestGap, date.timeIntervalSince(now))
    }

    private struct Record: Decodable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: TimeInterval
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        // Canonical Unicode, case and outer whitespace only. No punctuation
        // removal, diacritic folding, substring, album omission or search ranking.
        lhs.precomposedStringWithCanonicalMapping.lowercased() ==
            rhs.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func hasText(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func parse(_ source: String, track: LyricsLookupTrack) throws -> LyricsDocument {
        let document: LyricsDocument
        do { document = try LRCParser.parse(source) }
        catch { throw LyricsLookupError.invalidLyrics }
        for (key, expected) in [("ti", track.title), ("ar", track.artist), ("al", track.album)] {
            if let actual = document.metadata[key], !equal(actual, expected) {
                throw LyricsLookupError.identityMismatch
            }
        }
        return document
    }
}

/// Shared by the streaming adapter and fixtures. No Content-Length is needed;
/// overflow is rejected before it can grow the retained response buffer.
public struct LyricsResponseBuffer: Sendable {
    public private(set) var data = Data()
    public init() {}

    public mutating func append(_ chunk: Data) throws {
        guard chunk.count <= LRCLIBLookup.maximumResponseBytes - data.count else {
            throw LyricsLookupError.tooLarge
        }
        data.append(chunk)
    }
}

/// Single flight with no retries or cache. The controller additionally owns the
/// once-per-track policy, generation identity and cancellation when consent is
/// revoked. A cancelled/retired call can never return a late transport result.
public actor LyricsLookupClient {
    private let transport: any LyricsLookupTransport
    private let monotonicNow: @Sendable () -> TimeInterval
    private var inFlight = false
    private var notBefore: TimeInterval = 0

    public init(transport: any LyricsLookupTransport,
                monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.monotonicNow = monotonicNow
    }

    public func lookup(track: LyricsLookupTrack, consent: Bool) async throws -> LyricsLookupResult {
        let request = try LRCLIBLookup.request(track: track, consent: consent)
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        guard !inFlight else { throw LyricsLookupError.busy }
        let now = monotonicNow()
        guard now >= notBefore else { throw LyricsLookupError.rateLimited(retryAfter: notBefore - now) }
        inFlight = true
        defer {
            inFlight = false
            notBefore = max(notBefore, monotonicNow() + LRCLIBLookup.minimumRequestGap)
        }
        do {
            let response = try await transport.fetch(request)
            guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
            if response.statusCode == 429 || response.statusCode == 503 {
                // Honor the provider's delay even if the caller switches tracks.
                notBefore = max(notBefore, monotonicNow() + LRCLIBLookup.retryDelay(response.retryAfter))
            }
            let result = try LRCLIBLookup.decode(response, for: track, request: request)
            guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw LyricsLookupError.cancelled }
            throw (error as? LyricsLookupError) ?? .transportFailure
        }
    }
}

/// Pure half of the user-selected local import. No filename is interpreted as
/// identity and no directory, sidecar, Music library or online source is scanned.
public enum LyricsLocalImport {
    public static func parse(data: Data) throws -> LyricsDocument {
        guard data.count <= LRCParser.maximumInputBytes else { throw LyricsLookupError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw LyricsLookupError.invalidUTF8 }
        do { return try LRCParser.parse(text) }
        catch { throw LyricsLookupError.invalidLyrics }
    }
}
