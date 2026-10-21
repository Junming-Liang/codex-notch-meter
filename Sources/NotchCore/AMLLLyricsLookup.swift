import Foundation

/// Separate opt-in: an existing LRCLIB preference never grants AMLL consent.
public enum AMLLLookup {
    public static let consentKey = "musicLyricsAMLLFallbackEnabled"
    public static let pageSize = 20

    public static func request(track: LyricsLookupTrack, consent: Bool) throws -> LyricsLookupRequest {
        guard consent else { throw LyricsLookupError.consentRequired }
        // Without recording duration, require the album as additional identity.
        guard !track.album.isEmpty else { throw LyricsLookupError.invalidTrack }
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "api.amll.dev"; parts.path = "/v1/lrclib/search"
        parts.queryItems = [URLQueryItem(name: "track_name", value: track.title),
                            URLQueryItem(name: "artist_name", value: track.artist),
                            URLQueryItem(name: "album_name", value: track.album),
                            URLQueryItem(name: "pageSize", value: String(pageSize))]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url, isAllowed(url: url) else { throw LyricsLookupError.requestNotAllowed }
        return LyricsLookupRequest(url: url, method: "GET", timeout: LRCLIBLookup.requestTimeout,
            maximumResponseBytes: LRCLIBLookup.maximumResponseBytes, userAgent: LRCLIBLookup.userAgent)
    }

    public static func isAllowed(url: URL) -> Bool {
        guard let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              p.scheme == "https", p.host == "api.amll.dev", p.port == nil,
              p.user == nil, p.password == nil, p.fragment == nil,
              p.percentEncodedPath == "/v1/lrclib/search", let items = p.queryItems,
              items.count == 4, Set(items.map(\.name)) == Set(["track_name", "artist_name", "album_name", "pageSize"]),
              items.first(where: { $0.name == "pageSize" })?.value == String(pageSize),
              let title = items.first(where: { $0.name == "track_name" })?.value,
              let artist = items.first(where: { $0.name == "artist_name" })?.value,
              let album = items.first(where: { $0.name == "album_name" })?.value,
              let track = try? LyricsLookupTrack(title: title, artist: artist, album: album, duration: 1),
              !track.album.isEmpty else { return false }
        return true
    }

    /// Compatible API reviewed 2026-10-21: https://amll.dev/reference/http-api/lrclib
    /// Its duration is the highest lyric timestamp, NOT recording duration.
    /// Exact title/artist/album only; no punctuation deletion or catalogue-ID guesses.
    public static func decode(_ response: LyricsLookupResponse, for track: LyricsLookupTrack,
                              request: LyricsLookupRequest) throws -> LyricsLookupResult {
        guard isAllowed(url: response.url), response.url == request.url else { throw LyricsLookupError.requestNotAllowed }
        switch response.statusCode {
        case 429: throw LyricsLookupError.rateLimited(retryAfter: LRCLIBLookup.retryDelay(response.retryAfter))
        case 503: throw LyricsLookupError.serviceUnavailable(retryAfter: LRCLIBLookup.retryDelay(response.retryAfter))
        case 200: break
        default: throw LyricsLookupError.invalidResponse
        }
        guard response.body.count <= LRCLIBLookup.maximumResponseBytes else { throw LyricsLookupError.tooLarge }
        guard response.contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json" else {
            throw LyricsLookupError.invalidResponse
        }
        let records: [Record]
        do { records = try JSONDecoder().decode([Record].self, from: response.body) }
        catch { throw LyricsLookupError.invalidResponse }
        // Bare arrays lack hasMore; a full page cannot establish uniqueness.
        guard records.count < pageSize else { throw LyricsLookupError.identityMismatch }
        var selected: Record?
        for record in records {
            guard record.id > 0, record.duration.isFinite, record.duration >= 0,
                  !record.instrumental,
                  (try? LyricsLookupTrack(title: record.trackName, artist: record.artistName,
                      album: record.albumName, duration: 1)) != nil else { throw LyricsLookupError.invalidResponse }
            for text in [record.syncedLyrics, record.plainLyrics].compactMap({ $0 }) {
                guard text.utf8.count <= LRCParser.maximumInputBytes else { throw LyricsLookupError.tooLarge }
            }
            guard !track.album.isEmpty, equal(record.trackName, track.title),
                  equal(record.artistName, track.artist), equal(record.albumName, track.album) else { continue }
            // Even equal metadata may refer to competing timings/editions. Do
            // not rank or silently choose a candidate, including duplicate IDs.
            guard selected == nil else { throw LyricsLookupError.identityMismatch }
            selected = record
        }
        guard let record = selected else { return .noMatch }
        guard record.duration <= track.duration + LRCLIBLookup.durationTolerance else { throw LyricsLookupError.identityMismatch }
        let synced = record.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !synced.isEmpty || !plain.isEmpty else { return .unavailable }
        let document: LyricsDocument
        do { document = try LRCParser.parse(synced.isEmpty ? plain : synced) }
        catch { throw LyricsLookupError.invalidLyrics }
        for (key, expected) in [("ti", track.title), ("ar", track.artist), ("al", track.album)] {
            if let actual = document.metadata[key], !equal(actual, expected) { throw LyricsLookupError.identityMismatch }
        }
        if !synced.isEmpty {
            guard case .synchronized(let cues) = document.content,
                  cues.contains(where: { !$0.text.isEmpty }),
                  cues.allSatisfy({ $0.startTime <= track.duration + LRCLIBLookup.durationTolerance }) else {
                throw LyricsLookupError.invalidLyrics
            }
        } else if case .plain = document.content { } else { throw LyricsLookupError.invalidLyrics }
        return .matched(document)
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        func canonical(_ s: String) -> String {
            s.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return canonical(a) == canonical(b)
    }
    private struct Record: Decodable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let instrumental: Bool
        let syncedLyrics: String?
        let plainLyrics: String?
    }
}

/// One additional request per attempt; cooldown survives track/consent changes.
public actor AMLLLyricsClient {
    private let transport: any LyricsLookupTransport
    private let now: @Sendable () -> TimeInterval
    private var busy = false
    private var notBefore: TimeInterval = 0
    public init(transport: any LyricsLookupTransport,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport; self.now = now
    }
    public func lookup(track: LyricsLookupTrack, consent: Bool) async throws -> LyricsLookupResult {
        let request = try AMLLLookup.request(track: track, consent: consent)
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        guard !busy else { throw LyricsLookupError.busy }
        guard now() >= notBefore else { throw LyricsLookupError.rateLimited(retryAfter: notBefore - now()) }
        busy = true
        defer { busy = false; notBefore = max(notBefore, now() + LRCLIBLookup.minimumRequestGap) }
        do {
            let response = try await transport.fetch(request)
            guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
            if response.statusCode == 429 || response.statusCode == 503 {
                notBefore = max(notBefore, now() + LRCLIBLookup.retryDelay(response.retryAfter))
            }
            return try AMLLLookup.decode(response, for: track, request: request)
        } catch {
            if Task.isCancelled || error is CancellationError { throw LyricsLookupError.cancelled }
            throw (error as? LyricsLookupError) ?? .transportFailure
        }
    }
}

public struct SourcedLyricsResult: Equatable, Sendable {
    public let result: LyricsLookupResult
    public let source: String
}

/// A fallback miss must never turn an upstream outage into a confirmed no-match.
public enum DualLyricsLookup {
    public typealias Lookup = @Sendable (LyricsLookupTrack, Bool) async throws -> LyricsLookupResult
    public static func lookup(track: LyricsLookupTrack, lrclibConsent: Bool, amllConsent: Bool,
                              primary: Lookup, fallback: Lookup) async throws -> SourcedLyricsResult {
        guard lrclibConsent else { throw LyricsLookupError.consentRequired }
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        var primaryResult = LyricsLookupResult.noMatch
        var primaryError: LyricsLookupError?
        do {
            primaryResult = try await primary(track, true)
        } catch {
            let failure = (error as? LyricsLookupError) ?? .transportFailure
            if Task.isCancelled || error is CancellationError || failure == .cancelled { throw LyricsLookupError.cancelled }
            // Safety/identity failures are terminal, not permission to broaden matching.
            switch failure {
            case .offline, .timedOut, .transportFailure, .serviceUnavailable, .rateLimited: primaryError = failure
            default: throw failure
            }
        }
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        if case .matched = primaryResult { return SourcedLyricsResult(result: primaryResult, source: "LRCLIB 社区歌词") }
        guard amllConsent, !track.album.isEmpty else {
            if let primaryError { throw primaryError }
            return SourcedLyricsResult(result: primaryResult, source: "LRCLIB 社区歌词")
        }
        let secondary = try await fallback(track, true)
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        if case .matched = secondary { return SourcedLyricsResult(result: secondary, source: "AMLL 社区歌词") }
        if let primaryError { throw primaryError }
        return SourcedLyricsResult(result: primaryResult == .unavailable ? .unavailable : secondary, source: "")
    }
}
