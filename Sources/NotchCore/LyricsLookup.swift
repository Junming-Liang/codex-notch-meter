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
        self.album = try Self.validField(album, allowEmpty: true)
        // Duration remains mandatory even for album-free search; matching is
        // validated locally against this original duration.
        guard duration.isFinite, (1...3_600).contains(duration) else {
            throw LyricsLookupError.invalidTrack
        }
        self.duration = duration
    }

    private static func validField(_ value: String, allowEmpty: Bool = false) throws -> String {
        guard value.utf8.prefix(maximumFieldBytes + 1).count <= maximumFieldBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LyricsLookupError.invalidTrack
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !trimmed.isEmpty else { throw LyricsLookupError.invalidTrack }
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
    public static let userAgent = "CodexNotchMeter/1.1.4 (https://github.com/Junming-Liang/codex-notch-meter)"

    /// A search response at this ceiling may be truncated, so it cannot prove
    /// uniqueness. Reject it rather than selecting from a partial candidate set.
    // SEARCH_RESULT_LIMIT, reviewed 2026-10-16:
    // https://github.com/tranxuanthang/lrclib/blob/main/server/src/search_index.rs
    public static let maximumSearchResults = 20
    public static let maximumRequestsPerLookup = 3

    /// Exact lookup remains available to callers that explicitly need it.
    public static func request(track: LyricsLookupTrack, consent: Bool) throws -> LyricsLookupRequest {
        guard consent else { throw LyricsLookupError.consentRequired }
        guard !track.album.isEmpty else { throw LyricsLookupError.invalidTrack }
        return try makeRequest(path: "/api/get", items: [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(track.duration))
        ])
    }

    /// One same-provider, consent-gated chain, never fuzzy keyword discovery.
    /// LRCLIB q overrides structured fields, so search uses only title+artist.
    public static func requests(track: LyricsLookupTrack, consent: Bool) throws -> [LyricsLookupRequest] {
        guard consent else { throw LyricsLookupError.consentRequired }
        var result: [LyricsLookupRequest] = []
        if !track.album.isEmpty { result.append(try request(track: track, consent: true)) }
        var titles = [track.title]
        let normalized = presentationTitle(track.title)
        if !equal(normalized, track.title) { titles.append(normalized) }
        for title in titles {
            result.append(try makeRequest(path: "/api/search", items: [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: track.artist)
            ]))
        }
        guard result.count <= maximumRequestsPerLookup,
              Set(result.map { $0.url }).count == result.count else { throw LyricsLookupError.requestNotAllowed }
        return result
    }

    private static func makeRequest(path: String, items: [URLQueryItem]) throws -> LyricsLookupRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = items
        // Preserve literal plus signs in song/artist names.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, isAllowed(url: url) else { throw LyricsLookupError.requestNotAllowed }
        return LyricsLookupRequest(url: url, method: "GET", timeout: requestTimeout,
                                   maximumResponseBytes: maximumResponseBytes, userAgent: userAgent)
    }

    public static func isAllowed(url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "lrclib.net", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let items = parts.queryItems else { return false }
        let names = items.map(\.name)
        guard Set(names).count == names.count,
              let title = items.first(where: { $0.name == "track_name" })?.value,
              let artist = items.first(where: { $0.name == "artist_name" })?.value else { return false }
        if parts.percentEncodedPath == "/api/search" {
            guard Set(names) == Set(["track_name", "artist_name"]) else { return false }
            return (try? LyricsLookupTrack(title: title, artist: artist, album: "", duration: 1)) != nil
        }
        guard parts.percentEncodedPath == "/api/get",
              Set(names) == Set(["track_name", "artist_name", "album_name", "duration"]),
              let album = items.first(where: { $0.name == "album_name" })?.value, !album.isEmpty,
              let durationText = items.first(where: { $0.name == "duration" })?.value,
              let duration = Double(durationText),
              let track = try? LyricsLookupTrack(title: title, artist: artist, album: album, duration: duration),
              !track.album.isEmpty else { return false }
        return true
    }

    public static func decode(_ response: LyricsLookupResponse, for track: LyricsLookupTrack,
                              request: LyricsLookupRequest) throws -> LyricsLookupResult {
        try decodeResponse(response, for: track, request: request, exactMismatchIsNoMatch: false)
    }

    fileprivate static func decodeForLookup(_ response: LyricsLookupResponse, for track: LyricsLookupTrack,
                                           request: LyricsLookupRequest) throws -> LyricsLookupResult {
        try decodeResponse(response, for: track, request: request, exactMismatchIsNoMatch: true)
    }

    private static func decodeResponse(_ response: LyricsLookupResponse, for track: LyricsLookupTrack,
                                       request: LyricsLookupRequest,
                                       exactMismatchIsNoMatch: Bool) throws -> LyricsLookupResult {
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
        if request.url.path == "/api/search" {
            let records: [Record]
            do { records = try JSONDecoder().decode(SearchRecords.self, from: response.body).records }
            catch { throw LyricsLookupError.invalidResponse }
            return try select(records, for: track)
        }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: response.body) }
        catch { throw LyricsLookupError.invalidResponse }
        let identity = try validatedIdentity(record)
        guard equal(identity.title, track.title), equal(identity.artist, track.artist),
              equal(identity.album, track.album),
              abs(identity.duration - track.duration) <= durationTolerance else {
            if exactMismatchIsNoMatch { return .noMatch }
            throw LyricsLookupError.identityMismatch
        }
        return try lyrics(record, identity: identity, originalDuration: track.duration)
    }

    private static func select(_ records: [Record], for track: LyricsLookupTrack) throws -> LyricsLookupResult {
        var seen: [Int: Record] = [:]
        var strongest: (record: Record, identity: LyricsLookupTrack, rank: Int)?
        var ambiguous = false
        for record in records {
            let identity = try validatedIdentity(record)
            if let duplicate = seen[record.id] {
                guard duplicate == record else { throw LyricsLookupError.invalidResponse }
                continue
            }
            seen[record.id] = record
            guard equal(presentationTitle(identity.title), presentationTitle(track.title)),
                  equal(identity.artist, track.artist),
                  abs(identity.duration - track.duration) <= durationTolerance else { continue }
            // Album changes are common, but an explicitly different recording
            // edition must not pass merely because its title/duration agree.
            if hasRecordingMarker(identity.album) || hasRecordingMarker(track.album) {
                guard equal(presentationAlbum(identity.album), presentationAlbum(track.album)) else { continue }
            }
            let albumRank: Int
            if !track.album.isEmpty && equal(identity.album, track.album) { albumRank = 2 }
            else if !track.album.isEmpty && equal(presentationAlbum(identity.album), presentationAlbum(track.album)) {
                albumRank = 1
            } else { albumRank = 0 }
            let rank: Int = (equal(identity.title, track.title) ? 3 : 0) + albumRank
            if let current = strongest {
                if rank > current.rank {
                    strongest = (record, identity, rank)
                    ambiguous = false
                } else if rank == current.rank {
                    // Different IDs can duplicate one exact payload; collapse
                    // only equivalent identity, timing AND lyric content.
                    if !record.sameRecording(as: current.record) { ambiguous = true }
                }
            } else {
                strongest = (record, identity, rank)
            }
        }
        guard let selected = strongest else { return .noMatch }
        // Terminal: a broader query must not erase observed ambiguity.
        guard !ambiguous else { throw LyricsLookupError.identityMismatch }
        return try lyrics(selected.record, identity: selected.identity, originalDuration: track.duration)
    }

    private static func validatedIdentity(_ record: Record) throws -> LyricsLookupTrack {
        guard record.id > 0,
              let identity = try? LyricsLookupTrack(title: record.trackName, artist: record.artistName,
                                                    album: record.albumName, duration: record.duration) else {
            throw LyricsLookupError.invalidResponse
        }
        for text in [record.plainLyrics, record.syncedLyrics].compactMap({ $0 }) {
            guard text.utf8.count <= LRCParser.maximumInputBytes else { throw LyricsLookupError.tooLarge }
        }
        guard !record.instrumental || (!hasText(record.syncedLyrics) && !hasText(record.plainLyrics)) else {
            throw LyricsLookupError.invalidResponse
        }
        return identity
    }

    private static func lyrics(_ record: Record, identity: LyricsLookupTrack,
                               originalDuration: TimeInterval) throws -> LyricsLookupResult {
        if record.instrumental { return .matched(.instrumental) }
        if let synced = record.syncedLyrics, hasText(synced) {
            let document = try parse(synced, track: identity)
            if case .synchronized(let cues) = document.content {
                guard cues.contains(where: { !$0.text.isEmpty }),
                      cues.allSatisfy({ $0.startTime <= originalDuration + durationTolerance }) else {
                    throw LyricsLookupError.invalidLyrics
                }
                return .matched(document)
            }
            // Explicit plain field only. Never invent timing.
            guard hasText(record.plainLyrics) else { throw LyricsLookupError.invalidLyrics }
        }
        if let plain = record.plainLyrics, hasText(plain) {
            let document = try parse(plain, track: identity)
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

    private struct Record: Decodable, Equatable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: TimeInterval
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?

        func sameRecording(as other: Record) -> Bool {
            LRCLIBLookup.equal(trackName, other.trackName) && LRCLIBLookup.equal(artistName, other.artistName) &&
                LRCLIBLookup.equal(albumName, other.albumName) && duration == other.duration &&
                instrumental == other.instrumental && plainLyrics == other.plainLyrics &&
                syncedLyrics == other.syncedLyrics
        }
    }

    private struct SearchRecords: Decodable {
        let records: [Record]
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            if let count = container.count, count >= LRCLIBLookup.maximumSearchResults {
                throw LyricsLookupError.invalidResponse
            }
            var values: [Record] = []
            while !container.isAtEnd {
                guard values.count < LRCLIBLookup.maximumSearchResults - 1 else { throw LyricsLookupError.invalidResponse }
                values.append(try container.decode(Record.self))
            }
            records = values
        }
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ value: String) -> String {
        // No diacritic folding, punctuation deletion, transliteration or
        // simplified/traditional conversion. Only presentation whitespace.
        value.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Remove only a complete, recognized suffix, never arbitrary parentheses.
    /// Unknown qualifiers (including Part II and Reprise) remain identity-bearing.
    private static func presentationTitle(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let group = trailingGroup(result), !group.base.isEmpty,
              !hasRecordingMarker(group.suffix), isSoundtrackSuffix(group.suffix) {
            result = group.base
        }
        return result
    }

    private static func trailingGroup(_ value: String) -> (base: String, suffix: String)? {
        guard let last = value.last, last == ")" || last == "）" else { return nil }
        var stack: [Character] = []
        for index in value.indices.reversed() {
            let character = value[index]
            if character == ")" || character == "）" { stack.append(character) }
            else if character == "(" || character == "（" {
                guard let closing = stack.popLast(),
                      (character == "(" && closing == ")") || (character == "（" && closing == "）") else { return nil }
                if stack.isEmpty {
                    let base = String(value[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = String(value[value.index(after: index)..<value.index(before: value.endIndex)])
                    return (base, suffix)
                }
            }
        }
        return nil
    }

    private static func isSoundtrackSuffix(_ value: String) -> Bool {
        let normalized = canonical(value)
        guard !normalized.contains(where: { "()（）[]［］".contains($0) }) else { return false }
        let english = #"^from (?:the (?:motion picture|film|movie|tv series) )?(?:"[^"]+"|“[^”]+”|「[^」]+」|《[^》]+》)(?: (?:original )?(?:motion picture )?soundtrack)?$"#
        let chinese = #"^(?:电影|電影|电视剧|電視劇|电视|電視|网剧|網劇|动画|動畫)《[^《》]+》(?:主题曲|主題曲|片头曲|片頭曲|片尾曲|插曲)$"#
        return normalized.range(of: english, options: .regularExpression) != nil ||
            normalized.range(of: chinese, options: .regularExpression) != nil
    }

    private static func presentationAlbum(_ value: String) -> String {
        var result = canonical(value)
        let labels: Set<String> = ["deluxe", "deluxe edition", "expanded edition", "special edition",
                                   "豪华版", "豪華版", "加值版"]
        while let group = trailingGroup(result), labels.contains(canonical(group.suffix)), !group.base.isEmpty {
            result = group.base
        }
        for label in labels.sorted(by: { $0.count > $1.count }) {
            let suffix = " " + label
            if result.hasSuffix(suffix) {
                let base = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !base.isEmpty { return base }
            }
        }
        return result
    }

    private static func hasRecordingMarker(_ value: String) -> Bool {
        let normalized = canonical(value)
        let english = #"\b(?:live|remix|mix|acoustic|cover|karaoke|instrumental|edit|version|remaster(?:ed)?|demo|mono|stereo|clean|explicit|unplugged|reprise|re[ -]?record(?:ed|ing)?|sped[ -]?up|slowed|nightcore|translation|translated|english|chinese|mandarin|cantonese|japanese|korean|spanish|french|german|italian|portuguese)\b"#
        let chinese = ["现场", "現場", "混音", "重混", "不插电", "不插電", "原声版", "原聲版", "原音版",
                       "翻唱", "伴奏", "纯音乐", "純音樂", "器乐", "器樂", "卡拉", "清唱", "木吉他", "钢琴版", "鋼琴版", "剪辑", "剪輯", "剪辑版", "剪輯版",
                       "重制", "重製", "重录", "重錄", "母带", "母帶", "试听", "試聽", "单声道", "單聲道", "立体声", "立體聲",
                       "消音版", "无脏话", "無髒話", "加速", "减速", "減速", "慢速", "国语", "國語", "粤语", "粵語",
                       "普通话", "普通話", "中文版", "英文", "英语", "英語", "日文", "日语", "日語", "韩文", "韓文", "韩语", "韓語",
                       "台语", "台語", "闽南", "閩南", "法语", "法語", "德语", "德語", "西班牙", "译配", "譯配", "版本"]
        return normalized.range(of: english, options: .regularExpression) != nil ||
            chinese.contains(where: { normalized.contains($0) })
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

/// Single flight with bounded semantic fallback, no transport retry or cache.
/// The controller owns generation/consent cancellation and bounded transient retries.
/// A cancelled/retired call can never return a late transport result.
public actor LyricsLookupClient {
    private let transport: any LyricsLookupTransport
    private let monotonicNow: @Sendable () -> TimeInterval
    private let wait: @Sendable (TimeInterval) async throws -> Void
    private var inFlight = false
    private var notBefore: TimeInterval = 0

    public init(transport: any LyricsLookupTransport,
                monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                wait: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded(.up)))
                }) {
        self.transport = transport
        self.monotonicNow = monotonicNow
        self.wait = wait
    }

    public func lookup(track: LyricsLookupTrack, consent: Bool) async throws -> LyricsLookupResult {
        let requests = try LRCLIBLookup.requests(track: track, consent: consent)
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
            for (index, request) in requests.enumerated() {
                if index > 0 {
                    // Cancellable even after a successful HTTP no-match. Keep
                    // the single-flight slot while waiting between requests.
                    while monotonicNow() < notBefore {
                        try await wait(max(0, notBefore - monotonicNow()))
                        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
                    }
                }
                guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
                let response = try await transport.fetch(request)
                notBefore = max(notBefore, monotonicNow() + LRCLIBLookup.minimumRequestGap)
                guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
                if response.statusCode == 429 || response.statusCode == 503 {
                    // Preserve the delay across all phases and track changes.
                    notBefore = max(notBefore, monotonicNow() + LRCLIBLookup.retryDelay(response.retryAfter))
                }
                let result = try LRCLIBLookup.decodeForLookup(response, for: track, request: request)
                guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
                if result != .noMatch { return result }
            }
            return .noMatch
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
