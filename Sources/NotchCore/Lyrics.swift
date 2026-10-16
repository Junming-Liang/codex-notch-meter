import Foundation

/// A whole line, never an inferred word/syllable timing. A negative start can
/// result from a documented LRC offset and is already active at position zero.
public struct LyricCue: Equatable, Sendable {
    public let startTime: TimeInterval
    public let text: String
}

public struct LyricsDocument: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case unavailable
        case plain([String])
        case synchronized([LyricCue])
        case instrumental
    }

    public let content: Content
    public let metadata: [String: String]
    public let offsetMilliseconds: Int
    /// Malformed/unsupported lines, and untimed lines omitted from a timed file.
    public let ignoredLineCount: Int

    public static let unavailable = LyricsDocument(content: .unavailable)
    /// Use only with explicit source evidence. Empty text, missing timestamps,
    /// and Apple Music's hasLyrics flag cannot establish an instrumental track.
    public static let instrumental = LyricsDocument(content: .instrumental)

    fileprivate init(content: Content, metadata: [String: String] = [:],
                     offsetMilliseconds: Int = 0, ignoredLineCount: Int = 0) {
        self.content = content
        self.metadata = metadata
        self.offsetMilliseconds = offsetMilliseconds
        self.ignoredLineCount = ignoredLineCount
    }
}

/// Original, dependency-free parser for a deliberately bounded simple-LRC subset.
/// Accepts [m:ss], [mm:ss.f], [mm:ss.ff], [mm:ss.fff], up to four minute digits,
/// multiple leading timestamps, UTF-8 text, CR/LF/CRLF, and an initial BOM.
/// No enhanced/word timing is interpreted; angle-bracket tokens remain text.
public enum LRCParser {
    public static let maximumInputBytes = 262_144
    public static let maximumLines = 4_096
    public static let maximumLineBytes = 8_192
    public static let maximumTextBytes = 4_096
    public static let maximumMetadataBytes = 1_024
    public static let maximumTimestampsPerLine = 64
    public static let maximumCues = 8_192
    public static let maximumTime: TimeInterval = 86_400

    public enum ParseError: Error, Equatable, Sendable {
        case inputTooLarge, tooManyLines, tooManyCues
        case lineTooLong(line: Int), textTooLong(line: Int)
        case metadataTooLong(line: Int), tooManyTimestamps(line: Int)
    }

    /// Offset convention: positive milliseconds ADVANCE lyrics, so effective
    /// cue time = written timestamp - offset. Negative offsets delay lyrics.
    /// This explicitly supported convention follows the primary Liricle docs:
    /// https://github.com/mcanam/liricle#offset-gettersetter
    /// It is not a claim that all LRC producers use the same sign convention.
    /// Last valid offset/metadata wins, including tags after the timed lines.
    /// Duplicate timestamps use the last source occurrence (including blank
    /// clearing cues). Limits apply BEFORE deduplication; violations fail closed.
    public static func parse(_ input: String) throws -> LyricsDocument {
        guard input.utf8.prefix(maximumInputBytes + 1).count <= maximumInputBytes else {
            throw ParseError.inputTooLarge
        }
        var normalized = input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count <= maximumLines else { throw ParseError.tooManyLines }

        var metadata: [String: String] = [:]
        var offset = 0
        var ignored = 0
        var plain: [String] = []
        var rawCues: [(milliseconds: Int, text: String, order: Int)] = []
        let metadataKeys: Set<String> = ["ar", "al", "ti", "au", "length", "by", "re", "ve", "la"]

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            guard rawLine.utf8.count <= maximumLineBytes else {
                throw ParseError.lineTooLong(line: lineNumber)
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            var remaining = line[...]
            var times: [Int] = []
            var malformed = false
            while remaining.first == "[" {
                guard let end = remaining.firstIndex(of: "]") else { malformed = true; break }
                let body = remaining[remaining.index(after: remaining.startIndex)..<end]
                if let milliseconds = timestamp(body) {
                    times.append(milliseconds)
                    guard times.count <= maximumTimestampsPerLine else {
                        throw ParseError.tooManyTimestamps(line: lineNumber)
                    }
                    remaining = remaining[remaining.index(after: end)...]
                } else {
                    // A malformed numeric tag must not silently become lyric text.
                    if let first = body.utf8.first, (48...57).contains(first) || first == 43 || first == 45 {
                        malformed = true
                    }
                    break
                }
            }
            if malformed { ignored += 1; continue }

            if !times.isEmpty {
                let text = String(remaining).trimmingCharacters(in: .whitespaces)
                guard text.utf8.count <= maximumTextBytes else {
                    throw ParseError.textTooLong(line: lineNumber)
                }
                guard rawCues.count + times.count <= maximumCues else { throw ParseError.tooManyCues }
                for time in times { rawCues.append((time, text, rawCues.count)) }
                continue
            }

            if line.first == "[", let end = line.firstIndex(of: "]"),
               let colon = line[..<end].firstIndex(of: ":") {
                guard end == line.index(before: line.endIndex) else { ignored += 1; continue }
                let key = String(line[line.index(after: line.startIndex)..<colon]).lowercased()
                let value = String(line[line.index(after: colon)..<end])
                    .trimmingCharacters(in: .whitespaces)
                if key == "offset" {
                    if let parsed = signedMilliseconds(value) { offset = parsed }
                    else { ignored += 1 }
                } else if metadataKeys.contains(key) {
                    guard value.utf8.count <= maximumMetadataBytes else {
                        throw ParseError.metadataTooLong(line: lineNumber)
                    }
                    metadata[key] = value
                } else { ignored += 1 }
                continue
            }

            // Bracketed prose such as [Chorus] is still plain text. A broken
            // leading numeric timestamp was already rejected above.
            guard line.utf8.count <= maximumTextBytes else {
                throw ParseError.textTooLong(line: lineNumber)
            }
            plain.append(line)
        }

        let content: LyricsDocument.Content
        if rawCues.isEmpty {
            content = plain.isEmpty ? .unavailable : .plain(plain)
        } else {
            rawCues.sort {
                $0.milliseconds == $1.milliseconds ? $0.order < $1.order : $0.milliseconds < $1.milliseconds
            }
            var cues: [LyricCue] = []
            for raw in rawCues {
                let cue = LyricCue(startTime: Double(raw.milliseconds - offset) / 1_000, text: raw.text)
                if cues.last?.startTime == cue.startTime { cues[cues.count - 1] = cue }
                else { cues.append(cue) }
            }
            content = .synchronized(cues)
            ignored += plain.count
        }
        return LyricsDocument(content: content, metadata: metadata,
                              offsetMilliseconds: offset, ignoredLineCount: ignored)
    }

    private static func timestamp(_ text: Substring) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...4).contains(parts[0].utf8.count),
              let minutes = unsignedInteger(parts[0]) else { return nil }
        let seconds = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(seconds.count), seconds[0].utf8.count == 2,
              let whole = unsignedInteger(seconds[0]), whole < 60 else { return nil }
        var fraction = 0
        if seconds.count == 2 {
            let digits = seconds[1].utf8.count
            guard (1...3).contains(digits), let value = unsignedInteger(seconds[1]) else { return nil }
            fraction = value * (digits == 1 ? 100 : digits == 2 ? 10 : 1)
        }
        let milliseconds = (minutes * 60 + whole) * 1_000 + fraction
        return milliseconds <= Int(maximumTime * 1_000) ? milliseconds : nil
    }

    private static func unsignedInteger(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }

    private static func signedMilliseconds(_ text: String) -> Int? {
        var digits = text[...]
        var sign = 1
        if digits.first == "+" { digits = digits.dropFirst() }
        else if digits.first == "-" { sign = -1; digits = digits.dropFirst() }
        guard digits.utf8.count <= 8, let value = unsignedInteger(digits),
              value <= Int(maximumTime * 1_000) else { return nil }
        return sign * value
    }
}

/// In-memory line selection only: no wall clock, timers, files, providers or IPC.
/// All times must share ONE monotonic clock (for example systemUptime).
/// Rendering/polling never refreshes source freshness. Paused samples also expire.
public struct LyricsTimeline: Sendable {
    public enum Selection: Equatable, Sendable {
        case unavailable, instrumental, waitingForPlayback, stale, beforeFirstLine, gap, ended
        case plain([String])
        case line(index: Int, cue: LyricCue)
    }

    /// One selection and its honest whole-line preview. Playback/presentation
    /// policy remains the caller's responsibility; a fresh paused line is usable.
    public struct Preview: Equatable, Sendable {
        public let selection: Selection
        public let nextCue: LyricCue?

        public var currentText: String? {
            switch selection {
            case .line(_, let cue): return cue.text.isEmpty ? nil : cue.text
            case .plain(let lines):
                guard let first = lines.first, !first.isEmpty else { return nil }
                return first
            default: return nil
            }
        }

        /// Status labels, empty cues, and missing text never qualify as lyrics.
        public var isEligible: Bool { currentText != nil }

        /// Plain text stays explicitly unsynchronized, even when it is usable.
        public var isSynchronized: Bool {
            if case .line = selection { return true }
            return false
        }
    }

    public let freshnessInterval: TimeInterval
    public private(set) var generation: UInt64 = 0
    private var document: LyricsDocument = .unavailable
    private var replacedAt: TimeInterval = 0
    private var latestTime: TimeInterval?
    private var sample: Sample?

    private struct Sample: Sendable {
        let position: TimeInterval
        let isPlaying: Bool
        let duration: TimeInterval?
        let sampledAt: TimeInterval
    }

    public init(freshnessInterval: TimeInterval = 5) {
        self.freshnessInterval = freshnessInterval.isFinite && freshnessInterval > 0
            ? min(freshnessInterval, 30) : 5
    }

    /// Call for every track change, including replacement by the same track ID.
    /// Capture this token for asynchronous lyric and playback results. Replacing
    /// immediately clears both old lyrics and position. Invalid clocks do nothing.
    @discardableResult
    public mutating func replaceTrack(with lyrics: LyricsDocument = .unavailable,
                                      at now: TimeInterval) -> UInt64? {
        guard validClock(now), generation < UInt64.max else { return nil }
        generation += 1
        document = lyrics
        replacedAt = now
        latestTime = now
        sample = nil
        return generation
    }

    @discardableResult
    public mutating func setLyrics(_ lyrics: LyricsDocument, generation: UInt64) -> Bool {
        guard generation > 0, generation == self.generation else { return false }
        document = lyrics
        return true
    }

    /// A new sample is an authoritative anchor, including seeks in either
    /// direction, pause and resume. Receipt time is not observation time.
    /// Reject replayed/out-of-order, pre-replacement, future, stale or invalid
    /// samples without changing the existing anchor or clock watermark.
    @discardableResult
    public mutating func update(generation: UInt64, position: TimeInterval, isPlaying: Bool,
                                duration: TimeInterval? = nil, sampledAt: TimeInterval,
                                now: TimeInterval) -> Bool {
        guard generation > 0, generation == self.generation, validClock(now),
              position.isFinite, position >= 0, position <= LRCParser.maximumTime,
              sampledAt.isFinite, sampledAt >= replacedAt, sampledAt <= now,
              now - sampledAt < freshnessInterval,
              sample.map({ sampledAt > $0.sampledAt }) ?? true else { return false }
        if let duration {
            guard duration.isFinite, duration > 0, duration <= LRCParser.maximumTime else { return false }
        }
        sample = Sample(position: position, isPlaying: isPlaying, duration: duration, sampledAt: sampledAt)
        latestTime = now
        return true
    }

    /// Cues cover [start, next start). Before the first cue there is no active
    /// line. Only explicit empty cues establish gaps; silence is never guessed.
    /// The final cue lasts until an explicit duration ends, a replacement, or
    /// sample expiry. A paused fresh sample holds its exact reported position.
    /// Plain and instrumental content also require a fresh playback anchor;
    /// unavailable stays immediate. Losing the source must retire all display.
    /// Backward/invalid clock queries return stale without rewinding state.
    public mutating func selection(at now: TimeInterval) -> Selection {
        guard validClock(now) else { return .stale }
        latestTime = now
        if case .unavailable = document.content { return .unavailable }
        guard let sample else { return .waitingForPlayback }
        let elapsed = now - sample.sampledAt
        guard elapsed >= 0, elapsed < freshnessInterval else { return .stale }
        let position = sample.position + (sample.isPlaying ? elapsed : 0)
        if let duration = sample.duration, position >= duration { return .ended }
        switch document.content {
        case .unavailable: return .unavailable
        case .instrumental: return .instrumental
        case .plain(let lines): return .plain(lines)
        case .synchronized(let cues):
            // Upper bound chooses the last start <= position, with no linear
            // playback history. A seek back works just like an initial sample.
            var lower = 0
            var upper = cues.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if cues[middle].startTime <= position { lower = middle + 1 }
                else { upper = middle }
            }
            guard lower > 0 else { return .beforeFirstLine }
            let cue = cues[lower - 1]
            return cue.text.isEmpty ? .gap : .line(index: lower - 1, cue: cue)
        }
    }

    /// Selects once, retaining selection's clock, freshness and generation rules.
    /// The next line is only the immediately following normalized cue: never
    /// skip a blank clearing cue or manufacture timings for plain text. Cues
    /// starting at or beyond a known track end cannot become a next preview.
    public mutating func preview(at now: TimeInterval) -> Preview {
        let selected = selection(at: now)
        var nextCue: LyricCue?
        if case .line(let index, _) = selected,
           case .synchronized(let cues) = document.content,
           cues.indices.contains(index + 1) {
            let candidate = cues[index + 1]
            let duration = sample?.duration
            if !candidate.text.isEmpty,
               duration.map({ candidate.startTime < $0 }) ?? true {
                nextCue = candidate
            }
        }
        return Preview(selection: selected, nextCue: nextCue)
    }

    private func validClock(_ now: TimeInterval) -> Bool {
        now.isFinite && now >= 0 && (latestTime.map({ now >= $0 }) ?? true)
    }
}
