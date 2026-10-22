#if os(macOS)
import AppKit
import Combine
import NotchCore

/// Only this optional feature owns Music IPC and lyric lookup. It never invokes
/// quota refresh. Validated playback eligibility is consumed by the island's
/// single presentation owner; lyric/status strings are never eligibility inputs.
@MainActor
final class MusicLyricsController: ObservableObject {
    typealias Lookup = @Sendable (LyricsLookupTrack, Bool) async throws -> LyricsLookupResult
    typealias Import = @Sendable (URL) async throws -> LyricsDocument

    @Published private(set) var enabled: Bool
    @Published private(set) var onlineLookupEnabled: Bool
    @Published private(set) var amllFallbackEnabled: Bool
    @Published private(set) var trackTitle = ""
    @Published private(set) var line = ""
    @Published private(set) var nextLine = ""
    @Published private(set) var isSynchronized = false
    @Published private(set) var presentationRevision: UInt64 = 0
    @Published private(set) var statusText = "Apple Music 歌词未启用"
    @Published private(set) var sourceLabel = ""
    @Published private(set) var needsAuthorization = false
    @Published private(set) var hasLocalLyrics = false
    @Published private(set) var isPlayingForPresentation = false
    @Published private(set) var isFreshPlaying = false
    @Published private(set) var lyricsModeEnabled = false
    @Published private(set) var artwork: MusicArtwork?
    /// Same bounded pixels as artwork, prepared once per change and retired with
    /// that value. Frame-driven SwiftUI layout never constructs another image.
    private(set) var artworkImage: CGImage?
    private var syntheticArtworkImageBuilds: UInt64 = 0
    private var previewHeightCache = MusicPreviewLayout.Cache()
    var playbackRevision: UUID { trackRevision }

    /// Settings-only summary of the latest bounded provider status. No song
    /// metadata, event payloads, or persistent diagnostic history is exposed.
    var providerDiagnosticText: String? {
        guard enabled, let provider = reader as? MusicAppReader else { return nil }
        let read = provider.readDiagnostic, art = provider.artworkDiagnostic
        let seconds = String(format: "%.2f", read.elapsed)
        let failure = read.failure.map { String(describing: $0) } ?? "none"
        let artworkFailure = art.failure.map { String(describing: $0) } ?? "none"
        return "Music: \(read.phase) · \(seconds)s · \(failure)\nArtwork: \(art.phase) · \(artworkFailure)"
    }

    /// Reads only explicit non-content diagnostics. No title/artist/album,
    /// source label, lyrics, provider payload or localized error is serialized.
    func recordDebugState(sampled: Bool = false) {
        guard let capture = debugCapture, capture.isRecording else { return }
        if debugSession != capture.sessionID { debugSession = capture.sessionID; debugPresentationBase = presentationRevision }
        var values: [DebugCapture.Field: Double] = [.enabled: enabled ? 1 : 0,
            .fresh: isFreshPlaying ? 1 : 0, .playing: isPlayingForPresentation ? 1 : 0,
            .lyricsMode: lyricsModeEnabled ? 1 : 0, .presentationRevision: Double(presentationRevision &- debugPresentationBase),
            .playbackRevision: capture.identifier(trackRevision)]
        if let observed = current?.observedAt { values[.sourceAgeMs] = (clock() - observed) * 1000 }
        var labels: [DebugCapture.Label: DebugCapture.Value] = [.reason: .musicChanged]
        if let provider = reader as? MusicAppReader {
            let read = provider.readDiagnostic
            values[.readMs] = read.elapsed * 1000
            switch read.phase {
            case .idle: labels[.readPhase] = .idle
            case .target: labels[.readPhase] = .target
            case .permission: labels[.readPhase] = .permission
            case .stateBefore: labels[.readPhase] = .stateBefore
            case .trackBefore: labels[.readPhase] = .trackBefore
            case .position: labels[.readPhase] = .position
            case .trackAfter: labels[.readPhase] = .trackAfter
            case .stateAfter: labels[.readPhase] = .stateAfter
            case .validation: labels[.readPhase] = .validation
            }
            switch read.failure {
            case nil: labels[.readFailure] = DebugCapture.Value.none
            case .notRunning: labels[.readFailure] = .notRunning
            case .authorizationRequired, .permissionDenied: labels[.readFailure] = .denied
            case .timedOut: labels[.readFailure] = .timeout
            case .changedDuringRead: labels[.readFailure] = .changedTrack
            case .invalidResponse, .targetMismatch: labels[.readFailure] = .malformed
            case .unknownTrack, .cancelled, .busy: labels[.readFailure] = .unavailable
            case .appleEvent: labels[.readFailure] = .failed
            }
        }
        switch lookupState {
        case .idle: labels[.lookup] = .idle
        case .loading: labels[.lookup] = .loading
        case .matched: labels[.lookup] = .matched
        case .noMatch: labels[.lookup] = .noMatch
        case .unavailable: labels[.lookup] = .unavailable
        case .invalidMetadata: labels[.lookup] = .invalidMetadata
        case .identityMismatch: labels[.lookup] = .identityMismatch
        case .searchResultsTruncated: labels[.lookup] = .searchResultsTruncated
        case .waitingForProvider: labels[.lookup] = .waitingForProvider
        case .rateLimited: labels[.lookup] = .rateLimited
        case .serviceUnavailable: labels[.lookup] = .serviceUnavailable
        case .temporaryFailure: labels[.lookup] = .temporaryFailure
        case .rejected: labels[.lookup] = .rejected
        }
        capture.record(.music, sampled: sampled, values: values, labels: labels)
    }

    func previewContentHeight(width: CGFloat) -> CGFloat {
        previewHeightCache.contentHeight(trackRevision: trackRevision, line: line, nextLine: nextLine,
            width: width, countSyntheticMeasurement: synthetic)
    }

    var syntheticArtworkImageBuildCount: UInt64? { synthetic ? syntheticArtworkImageBuilds : nil }
    var syntheticPreviewHeightMeasurementCount: UInt64? { synthetic ? previewHeightCache.syntheticMeasurementCount : nil }

    private func setArtwork(_ value: MusicArtwork?) {
        guard artwork != value else { return }
        artworkImage = value.flatMap { art in
            if synthetic { syntheticArtworkImageBuilds &+= 1 }
            guard let provider = CGDataProvider(data: art.rgbaBytes as CFData),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(width: art.pixelWidth, height: art.pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: art.bytesPerRow, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        artwork = value
    }

    /// Session choice; unavailable content never invents a lyric or opens a card.
    func selectLyricsMode(_ value: Bool) {
        guard !stopped, enabled, lyricsModeEnabled != value else { return }
        guard !value || isPlayingForPresentation else { return }
        lyricsModeEnabled = value; presentationRevision &+= 1
    }
    @Published private(set) var lookupState = LyricsLookupState.idle
    let synthetic: Bool
    weak var debugCapture: DebugCapture?
    private var debugSession: UUID?
    private var debugPresentationBase: UInt64 = 0

    private let defaults: UserDefaults?
    private let reader: any MusicSnapshotProvider
    private let lookup: Lookup
    private let amllLookup: Lookup
    private let importer: Import
    private let clock: () -> TimeInterval
    private var timeline = LyricsTimeline()
    private var document = LyricsDocument.unavailable
    private var current: MusicPlaybackSnapshot?
    /// One in-memory successful document, never a display/playback anchor.
    /// Only an exact, freshly confirmed track may reclaim it after a soft read failure.
    private struct RetainedLyrics {
        let track: MusicTrackIdentity
        let document: LyricsDocument
        let isLocal: Bool
        let sourceLabel: String
    }
    private var retainedLyrics: RetainedLyrics?
    private var pollTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var lineTimer: Timer?
    private var epoch = UUID()
    private var trackRevision = UUID()
    private var lookupGeneration: UInt64?
    private var lookupAttempts = 0
    private var lookupRetryAt: TimeInterval?
    private var lookupNotBefore: TimeInterval = 0
    private var lookupCooldownState = LyricsLookupState.temporaryFailure
    private var started = false
    private var active = true
    private var stopped = false

    init(synthetic: Bool, reader: (any MusicSnapshotProvider)? = nil,
         lookup: Lookup? = nil, amllLookup: Lookup? = nil, importer: Import? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.synthetic = synthetic
        defaults = synthetic ? nil : .standard
        enabled = synthetic ? false : (UserDefaults.standard.object(forKey: "musicLyricsEnabled") as? Bool ?? false)
        onlineLookupEnabled = synthetic ? false : (UserDefaults.standard.object(forKey: "musicLyricsOnlineLookupEnabled") as? Bool ?? false)
        amllFallbackEnabled = synthetic ? false : (UserDefaults.standard.object(forKey: AMLLLookup.consentKey) as? Bool ?? false)
        if let amllLookup { self.amllLookup = amllLookup }
        else if synthetic { self.amllLookup = { _, _ in throw LyricsLookupError.consentRequired } }
        else {
            let provider = AMLLLyricsProvider()
            self.amllLookup = { try await provider.lookup(track: $0, consent: $1) }
        }
        if let reader { self.reader = reader }
        else if synthetic { self.reader = SilentMusicReader() }
        else { self.reader = MusicAppReader() }
        if let lookup { self.lookup = lookup }
        else if synthetic { self.lookup = { _, _ in throw LyricsLookupError.consentRequired } }
        else {
            let provider = LRCLIBLyricsProvider()
            self.lookup = { try await provider.lookup(track: $0, consent: $1) }
        }
        if let importer { self.importer = importer }
        else if synthetic { self.importer = { _ in throw LyricsLookupError.fileUnavailable } }
        else { self.importer = { try await LocalLyricsImporter.load(userSelectedURL: $0) } }
        self.clock = clock
        if enabled { statusText = "等待 Music 播放信息" }
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        // Restored preferences never authorize a new system permission prompt.
        beginPolling(allowPermissionPrompt: false)
    }

    func setEnabled(_ value: Bool) {
        guard !stopped, enabled != value else { return }
        enabled = value
        if !value { lyricsModeEnabled = false }
        defaults?.set(value, forKey: "musicLyricsEnabled")
        retireWork()
        clearPlayback()
        if value {
            statusText = "正在读取 Music 播放信息…"
            // This method is called only by the explicit Settings toggle.
            beginPolling(allowPermissionPrompt: true)
        } else { statusText = "Apple Music 歌词未启用" }
    }

    func requestAuthorization() {
        guard enabled, active, !stopped else { return }
        retireWork()
        clearPlayback()
        beginPolling(allowPermissionPrompt: true)
    }

    func setOnlineLookupEnabled(_ value: Bool) {
        guard !stopped, onlineLookupEnabled != value else { return }
        onlineLookupEnabled = value
        if !value, retainedLyrics?.isLocal == false { retainedLyrics = nil }
        defaults?.set(value, forKey: "musicLyricsOnlineLookupEnabled")
        lookupTask?.cancel(); lookupTask = nil; lookupGeneration = nil
        resetLookupState()
        if !hasLocalLyrics {
            document = .unavailable
            _ = timeline.setLyrics(.unavailable, generation: timeline.generation)
            line = ""; sourceLabel = ""
            statusText = value ? "等待歌词匹配" : "可为当前歌曲导入 LRC 歌词"
        }
        refreshLine()
        if value { beginLookupIfNeeded() }
    }

    func setAMLLFallbackEnabled(_ value: Bool) {
        guard !stopped, amllFallbackEnabled != value else { return }
        amllFallbackEnabled = value
        defaults?.set(value, forKey: AMLLLookup.consentKey)
        lookupTask?.cancel(); lookupTask = nil; lookupGeneration = nil
        // Retained online results must not survive revocation of their source.
        if retainedLyrics?.isLocal == false { retainedLyrics = nil }
        resetLookupState()
        if !hasLocalLyrics {
            document = .unavailable
            _ = timeline.setLyrics(.unavailable, generation: timeline.generation)
            line = ""; sourceLabel = ""
        }
        refreshLine()
        beginLookupIfNeeded()
    }

    /// Sleep, inactive session, display sleep and hide suspend independent work.
    func setActive(_ value: Bool) {
        guard active != value, !stopped else { return }
        active = value
        retireWork(); clearPlayback()
        guard enabled else { return }
        statusText = value ? "等待 Music 播放信息" : "歌词已暂停"
        if value { beginPolling(allowPermissionPrompt: false) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        retireWork(); clearPlayback()
    }

    var canImport: Bool {
        guard enabled, active, !stopped, let value = current else { return false }
        let age = clock() - value.observedAt
        return age >= 0 && age < timeline.freshnessInterval
    }

    var importSelectionToken: UUID? { canImport ? trackRevision : nil }

    // Read-only native-fixture receipts. Real playback never exposes these
    // probes; they neither publish changes nor alter asynchronous completion.
    var syntheticPlaybackSnapshot: MusicPlaybackSnapshot? { synthetic ? current : nil }
    var syntheticLyricsDocument: LyricsDocument? { synthetic ? document : nil }

    func importLyrics(from userSelectedURL: URL, for selectionToken: UUID) {
        guard canImport, selectionToken == trackRevision, let track = current?.track else { return }
        importTask?.cancel()
        let token = epoch
        let generation = timeline.generation
        let revision = trackRevision
        statusText = "正在读取所选歌词文件…"
        importTask = Task { [weak self, importer] in
            do {
                let value = try await importer(userSelectedURL)
                guard let self, !Task.isCancelled, self.epoch == token,
                      self.enabled, self.active, self.current?.track == track,
                      self.timeline.generation == generation, self.trackRevision == revision else { return }
                self.lookupTask?.cancel(); self.lookupTask = nil
                self.lookupGeneration = generation
                self.document = value; self.hasLocalLyrics = true
                self.sourceLabel = "本地歌词"
                _ = self.timeline.setLyrics(value, generation: generation)
                self.refreshLine()
            } catch {
                guard let self, !Task.isCancelled, self.epoch == token,
                      self.current?.track == track, self.trackRevision == revision else { return }
                self.statusText = "无法读取所选歌词，请选择有效的 UTF-8 LRC 或文本文件"
            }
        }
    }

    var canClearLocalLyrics: Bool { hasLocalLyrics || retainedLyrics?.isLocal == true }

    func clearLocalLyrics() {
        guard hasLocalLyrics || retainedLyrics?.isLocal == true else { return }
        retainedLyrics = nil
        importTask?.cancel(); importTask = nil
        hasLocalLyrics = false; document = .unavailable; sourceLabel = ""; line = ""
        _ = timeline.setLyrics(.unavailable, generation: timeline.generation)
        lookupGeneration = nil
        resetLookupState()
        statusText = "可为当前歌曲导入 LRC 歌词"
        refreshLine()
        beginLookupIfNeeded()
    }

    private func retireWork() {
        epoch = UUID()
        pollTask?.cancel(); pollTask = nil
        lookupTask?.cancel(); lookupTask = nil
        importTask?.cancel(); importTask = nil
        lineTimer?.invalidate(); lineTimer = nil
        lookupGeneration = nil
    }

    private func clearPlayback(retainingSuccessfulLyrics: Bool = false) {
        // Retire optional provider work together with presentation eligibility.
        // This never extends the last mandatory playback observation.
        reader.invalidate()
        if retainingSuccessfulLyrics {
            if let track = current?.track {
                if case .unavailable = document.content {
                    // No successfully parsed document exists to recover.
                } else {
                    retainedLyrics = RetainedLyrics(track: track, document: document,
                        isLocal: hasLocalLyrics, sourceLabel: sourceLabel)
                }
            }
        } else { retainedLyrics = nil }
        let hadPresentation = isPlayingForPresentation || isFreshPlaying || !line.isEmpty || !nextLine.isEmpty
        if isPlayingForPresentation { isPlayingForPresentation = false }
        if isFreshPlaying { isFreshPlaying = false }
        setArtwork(nil)
        previewHeightCache.clear()
        nextLine = ""; isSynchronized = false
        if hadPresentation { presentationRevision &+= 1 }
        trackRevision = UUID()
        _ = timeline.replaceTrack(at: clock())
        current = nil; document = .unavailable
        trackTitle = ""; line = ""; sourceLabel = ""
        hasLocalLyrics = false; needsAuthorization = false
        resetLookupState()
    }

    private func resetLookupState() {
        lookupAttempts = 0; lookupRetryAt = nil; lookupState = .idle
    }

    private func beginPolling(allowPermissionPrompt: Bool) {
        guard started, enabled, active, !stopped, pollTask == nil else { return }
        let token = epoch
        pollTask = Task { [weak self, reader] in
            var prompt = allowPermissionPrompt
            while !Task.isCancelled {
                let result = await reader.read(allowPermissionPrompt: prompt)
                prompt = false
                guard let self, self.epoch == token, self.enabled,
                      self.active, !self.stopped, !Task.isCancelled else { return }
                self.receive(result)
                if self.needsAuthorization {
                    self.pollTask = nil
                    return
                }
                let delay: UInt64 = self.current?.state == .playing ? 1_000_000_000 : 3_000_000_000
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
            }
        }
    }

    private func receive(_ result: MusicReadResult) {
        defer { recordDebugState() }
        switch result {
        case .unavailable(let reason):
            lookupTask?.cancel(); lookupTask = nil; lookupGeneration = nil
            importTask?.cancel(); importTask = nil
            lineTimer?.invalidate(); lineTimer = nil
            // Even a timeout may have occurred after observing a pause. Hide
            // immediately; retaining a document never extends source freshness.
            let recoverable: Bool
            switch reason {
            case .timedOut, .busy, .changedDuringRead, .unknownTrack: recoverable = true
            default: recoverable = false
            }
            clearPlayback(retainingSuccessfulLyrics: recoverable)
            switch reason {
            case .authorizationRequired:
                needsAuthorization = true; statusText = "需要允许读取 Music；请在设置中请求授权"
            case .permissionDenied:
                needsAuthorization = true; statusText = "Music 自动化权限未允许；可在系统设置中检查"
            case .notRunning: statusText = "请打开 Music 并播放歌曲"
            case .unknownTrack, .changedDuringRead: statusText = "Music 播放信息暂不可用"
            case .timedOut, .busy: statusText = "Music 暂未响应，已停止显示旧歌词"
            case .cancelled: statusText = "歌词读取已取消"
            case .invalidResponse, .targetMismatch, .appleEvent:
                statusText = "Music 播放信息不可用，已停止显示旧歌词"
            }
        case .snapshot(let value):
            guard value.state == .playing || value.state == .paused else {
                // A confirmed stopped/unknown snapshot is not a transient
                // unknown-track read. It retires any recovery binding as well.
                clearPlayback()
                receive(.unavailable(.unknownTrack)); return
            }
            let now = clock()
            guard value.observedAt <= now, now - value.observedAt < timeline.freshnessInterval else {
                receive(.unavailable(.invalidResponse)); return
            }
            if current?.track != value.track {
                trackRevision = UUID()
                previewHeightCache.clear()
                presentationRevision &+= 1
                lookupTask?.cancel(); lookupTask = nil; lookupGeneration = nil
                importTask?.cancel(); importTask = nil
                document = .unavailable; hasLocalLyrics = false; sourceLabel = ""; line = ""
                resetLookupState()
                // The observed sample predates its receipt; use that observation
                // as the new generation's earliest valid anchor.
                timeline = LyricsTimeline()
                _ = timeline.replaceTrack(at: value.observedAt)
            }
            guard timeline.update(generation: timeline.generation, position: value.position,
                                  isPlaying: value.state == .playing, duration: value.track.duration,
                                  sampledAt: value.observedAt, now: now) else {
                receive(.unavailable(.invalidResponse)); return
            }
            current = value
            if needsAuthorization { needsAuthorization = false }
            if trackTitle != value.track.title { trackTitle = value.track.title }
            if let retained = retainedLyrics {
                // Consume the slot on the first validated sample, even when it
                // is another song. Never carry A through B and revive it later.
                retainedLyrics = nil
                if retained.track == value.track && (retained.isLocal || onlineLookupEnabled) {
                    document = retained.document; hasLocalLyrics = retained.isLocal
                    sourceLabel = retained.sourceLabel
                    _ = timeline.setLyrics(retained.document, generation: timeline.generation)
                    lookupGeneration = timeline.generation
                    if !retained.isLocal { lookupState = .matched }
                }
            }
            setArtwork(value.artwork)
            refreshLine()
            beginLookupIfNeeded()
        }
    }

    private func beginLookupIfNeeded() {
        guard enabled, onlineLookupEnabled, active, !stopped, !hasLocalLyrics,
              lookupTask == nil, canImport, let value = current else { return }
        guard clock() >= lookupNotBefore else {
            if lookupState != lookupCooldownState { lookupState = lookupCooldownState }
            let status = lookupStatusText
            if statusText != status { statusText = status }
            return
        }
        if lookupGeneration == timeline.generation {
            guard value.state == .playing, let retryAt = lookupRetryAt,
                  clock() >= retryAt, lookupAttempts < LyricsRetryPolicy.maximumAttempts else { return }
        }
        let generation = timeline.generation
        lookupGeneration = generation
        guard let track = try? LyricsLookupTrack(title: value.track.title, artist: value.track.artist,
                                                album: value.track.album, duration: value.track.duration) else {
            lookupState = .invalidMetadata
            statusText = "歌曲信息不足以可靠匹配在线歌词，可导入本地 LRC"
            return
        }
        lookupAttempts += 1; lookupRetryAt = nil; lookupState = .loading
        let token = epoch
        let identity = value.track
        let revision = trackRevision
        statusText = lookupStatusText
        let amllConsent = amllFallbackEnabled
        lookupTask = Task { [weak self, lookup, amllLookup] in
            do {
                let sourced = try await DualLyricsLookup.lookup(track: track, lrclibConsent: true,
                    amllConsent: amllConsent, primary: lookup, fallback: amllLookup)
                let result = sourced.result
                guard let self, !Task.isCancelled, self.epoch == token, self.enabled,
                      self.active, self.onlineLookupEnabled, self.amllFallbackEnabled == amllConsent, self.current?.track == identity,
                      self.timeline.generation == generation, self.trackRevision == revision, !self.hasLocalLyrics else { return }
                self.lookupTask = nil
                switch result {
                case .matched(let value):
                    self.lookupState = .matched
                    self.document = value; self.sourceLabel = sourced.source
                    _ = self.timeline.setLyrics(value, generation: generation)
                    self.refreshLine()
                case .noMatch: self.lookupState = .noMatch; self.statusText = self.lookupStatusText
                case .unavailable: self.lookupState = .unavailable; self.statusText = self.lookupStatusText
                }
            } catch {
                guard let self, !Task.isCancelled, self.epoch == token,
                      self.current?.track == identity, self.trackRevision == revision else { return }
                self.lookupTask = nil
                let reason = (error as? LyricsLookupError) ?? .transportFailure
                // A cancelled previous track may still own the provider's sole
                // slot, or its local request-spacing window may still be open.
                // Neither sent this track's request nor consumed a network retry.
                switch reason {
                case .busy, .deferred: self.lookupAttempts = max(0, self.lookupAttempts - 1)
                default: break
                }
                self.lookupState = .failure(reason)
                switch reason {
                case .rateLimited, .serviceUnavailable:
                    // Each retained provider enforces its own server cooldown.
                    // Keep this track's retry schedule below, but let another
                    // track use a healthy provider instead of blocking both.
                    break
                default:
                    if let deadline = LyricsRetryPolicy.cooldownUntil(after: reason,
                        completedAttempts: self.lookupAttempts, now: self.clock()) {
                        self.lookupNotBefore = max(self.lookupNotBefore, deadline)
                        self.lookupCooldownState = self.lookupState
                    }
                }
                self.lookupRetryAt = LyricsRetryPolicy.nextAttemptAt(after: reason,
                    completedAttempts: self.lookupAttempts, now: self.clock())
                self.statusText = self.lookupStatusText
            }
        }
    }

    private var lookupStatusText: String {
        guard onlineLookupEnabled else { return "可为当前歌曲导入 LRC 歌词" }
        switch lookupState {
        case .idle: return "等待歌词匹配"
        case .loading: return amllFallbackEnabled ? "正在匹配歌词（LRCLIB → AMLL）…" : "正在向 LRCLIB 匹配歌词…"
        case .matched, .unavailable: return "匹配记录暂无可用歌词，可导入本地 LRC"
        case .noMatch: return "未找到匹配歌词，可导入本地 LRC"
        case .invalidMetadata: return "歌曲信息不足以可靠匹配在线歌词，可导入本地 LRC"
        case .identityMismatch: return "匹配结果版本不一致，可导入本地 LRC"
        case .searchResultsTruncated: return "匹配候选过多，无法确认歌曲版本；可导入本地 LRC"
        case .waitingForProvider: return "正在等待歌词请求就绪…"
        case .rateLimited: return "歌词服务请求受限，可稍后重试或导入本地 LRC"
        case .serviceUnavailable: return "歌词服务暂不可用，可稍后重试或导入本地 LRC"
        case .temporaryFailure: return "在线歌词暂时读取失败，可稍后重试或导入本地 LRC"
        case .rejected: return "歌词响应无法安全使用，可导入本地 LRC"
        }
    }

    private func refreshLine() {
        defer { recordDebugState(sampled: true) }
        lineTimer?.invalidate(); lineTimer = nil
        let now = clock()
        let previous = (line, nextLine, isSynchronized, isPlayingForPresentation, isFreshPlaying)
        let preview = timeline.preview(at: now)
        var selection = preview.selection
        // Derive the final presentation before publishing. An unchanged playback
        // poll still advances freshness/timers, but cannot invalidate every view
        // or briefly publish an empty next cue / unsynchronized current cue.
        var text = "", followingText = "", synchronized = false
        var title = trackTitle
        let status: String
        // An unavailable lyric document intentionally short-circuits the pure
        // timeline. Source freshness still governs the visible song metadata.
        if let value = current {
            let age = now - value.observedAt
            if !age.isFinite || age < 0 || age >= timeline.freshnessInterval { selection = .stale }
        }
        let playing: Bool
        if enabled, active, !stopped, let value = current {
            let age = now - value.observedAt
            playing = value.state == .playing && age.isFinite && age >= 0
                && age < timeline.freshnessInterval && value.position + age < value.track.duration
        } else { playing = false }
        switch selection {
        case .line(_, let cue):
            text = cue.text; followingText = preview.nextCue?.text ?? ""; synchronized = true
            status = current?.state == .paused ? "已暂停" : "同步歌词"
        case .plain(let lines): text = lines.first ?? ""; status = "纯文本歌词 · 未同步"
        case .instrumental: status = "纯音乐"
        case .beforeFirstLine: status = "等待第一句歌词"
        case .gap: status = "间奏"
        case .ended: status = "播放已结束"
        case .stale: title = ""; status = "Music 播放信息已过期"
        case .waitingForPlayback: status = "等待播放位置"
        case .unavailable: status = lookupStatusText
        }
        // Pause hides the music presentation immediately; keep only internal
        // track/document identity so a fresh resume can select its current cue.
        if current?.state == .paused {
            text = ""; followingText = ""; synchronized = false
        }
        let finalStatus = current?.state == .paused && !title.isEmpty ? "已暂停" : status
        let eligible = playing && preview.isEligible && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !eligible { text = ""; followingText = ""; synchronized = false }
        if trackTitle != title { trackTitle = title }
        if line != text { line = text }
        if nextLine != followingText { nextLine = followingText }
        if isSynchronized != synchronized { isSynchronized = synchronized }
        if statusText != finalStatus { statusText = finalStatus }
        if isFreshPlaying != playing { isFreshPlaying = playing }
        if !playing { setArtwork(nil) }
        if isPlayingForPresentation != eligible { isPlayingForPresentation = eligible }
        if previous.0 != line || previous.1 != nextLine || previous.2 != isSynchronized || previous.3 != eligible || previous.4 != playing {
            presentationRevision &+= 1
        }
        guard enabled, active, !stopped, let value = current else { return }
        var next = value.observedAt + timeline.freshnessInterval
        if value.state == .playing, case .synchronized(let cues) = document.content {
            let position = value.position + max(0, now - value.observedAt)
            if let cue = cues.first(where: { $0.startTime > position }) {
                next = min(next, now + cue.startTime - position)
            }
            next = min(next, now + max(0, value.track.duration - position))
        }
        guard next > now else { return }
        let token = epoch
        lineTimer = Timer.scheduledTimer(withTimeInterval: max(0.02, next - now), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.epoch == token else { return }
                self.refreshLine()
            }
        }
    }
}

private struct SilentMusicReader: MusicSnapshotProvider {
    func read(allowPermissionPrompt: Bool) async -> MusicReadResult { .unavailable(.notRunning) }
}
#endif
