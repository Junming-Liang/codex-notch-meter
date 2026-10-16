#if os(macOS)
import AppKit
import Combine
import NotchCore

/// Only this optional feature owns Music IPC and lyric lookup. It never invokes
/// quota refresh or changes island geometry/presentation priority.
@MainActor
final class MusicLyricsController: ObservableObject {
    typealias Lookup = @Sendable (LyricsLookupTrack, Bool) async throws -> LyricsLookupResult
    typealias Import = @Sendable (URL) async throws -> LyricsDocument

    @Published private(set) var enabled: Bool
    @Published private(set) var onlineLookupEnabled: Bool
    @Published private(set) var trackTitle = ""
    @Published private(set) var line = ""
    @Published private(set) var statusText = "Apple Music 歌词未启用"
    @Published private(set) var sourceLabel = ""
    @Published private(set) var needsAuthorization = false
    @Published private(set) var hasLocalLyrics = false
    let synthetic: Bool

    private let defaults: UserDefaults?
    private let reader: any MusicSnapshotProvider
    private let lookup: Lookup
    private let importer: Import
    private let clock: () -> TimeInterval
    private var timeline = LyricsTimeline()
    private var document = LyricsDocument.unavailable
    private var current: MusicPlaybackSnapshot?
    private var pollTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var lineTimer: Timer?
    private var epoch = UUID()
    private var trackRevision = UUID()
    private var lookupGeneration: UInt64?
    private var started = false
    private var active = true
    private var stopped = false

    init(synthetic: Bool, reader: (any MusicSnapshotProvider)? = nil,
         lookup: Lookup? = nil, importer: Import? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.synthetic = synthetic
        defaults = synthetic ? nil : .standard
        enabled = synthetic ? false : (UserDefaults.standard.object(forKey: "musicLyricsEnabled") as? Bool ?? false)
        onlineLookupEnabled = synthetic ? false : (UserDefaults.standard.object(forKey: "musicLyricsOnlineLookupEnabled") as? Bool ?? false)
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
        defaults?.set(value, forKey: "musicLyricsOnlineLookupEnabled")
        lookupTask?.cancel(); lookupTask = nil; lookupGeneration = nil
        if !hasLocalLyrics {
            document = .unavailable
            _ = timeline.setLyrics(.unavailable, generation: timeline.generation)
            line = ""; sourceLabel = ""
            statusText = value ? "等待歌词匹配" : "可为当前歌曲导入 LRC 歌词"
        }
        if value { beginLookupIfNeeded() }
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

    func clearLocalLyrics() {
        guard hasLocalLyrics else { return }
        importTask?.cancel(); importTask = nil
        hasLocalLyrics = false; document = .unavailable; sourceLabel = ""; line = ""
        _ = timeline.setLyrics(.unavailable, generation: timeline.generation)
        lookupGeneration = nil
        statusText = "可为当前歌曲导入 LRC 歌词"
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

    private func clearPlayback() {
        trackRevision = UUID()
        _ = timeline.replaceTrack(at: clock())
        current = nil; document = .unavailable
        trackTitle = ""; line = ""; sourceLabel = ""
        hasLocalLyrics = false; needsAuthorization = false
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
        switch result {
        case .unavailable(let reason):
            lookupTask?.cancel(); lookupTask = nil; lookupGeneration = nil
            importTask?.cancel(); importTask = nil
            lineTimer?.invalidate(); lineTimer = nil
            clearPlayback()
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
                receive(.unavailable(.unknownTrack)); return
            }
            let now = clock()
            guard value.observedAt <= now, now - value.observedAt < timeline.freshnessInterval else {
                receive(.unavailable(.invalidResponse)); return
            }
            if current?.track != value.track {
                trackRevision = UUID()
                lookupTask?.cancel(); lookupTask = nil; lookupGeneration = nil
                importTask?.cancel(); importTask = nil
                document = .unavailable; hasLocalLyrics = false; sourceLabel = ""; line = ""
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
            current = value; needsAuthorization = false; trackTitle = value.track.title
            refreshLine()
            beginLookupIfNeeded()
        }
    }

    private func beginLookupIfNeeded() {
        guard enabled, onlineLookupEnabled, active, !stopped, !hasLocalLyrics,
              lookupTask == nil, canImport, let value = current,
              lookupGeneration != timeline.generation else { return }
        let generation = timeline.generation
        lookupGeneration = generation
        guard let track = try? LyricsLookupTrack(title: value.track.title, artist: value.track.artist,
                                                album: value.track.album, duration: value.track.duration) else {
            statusText = "歌曲信息不足以可靠匹配在线歌词，可导入本地 LRC"
            return
        }
        let token = epoch
        let identity = value.track
        let revision = trackRevision
        statusText = "正在向 LRCLIB 匹配歌词…"
        lookupTask = Task { [weak self, lookup] in
            do {
                let result = try await lookup(track, true)
                guard let self, !Task.isCancelled, self.epoch == token, self.enabled,
                      self.active, self.onlineLookupEnabled, self.current?.track == identity,
                      self.timeline.generation == generation, self.trackRevision == revision, !self.hasLocalLyrics else { return }
                self.lookupTask = nil
                switch result {
                case .matched(let value):
                    self.document = value; self.sourceLabel = "LRCLIB 社区歌词"
                    _ = self.timeline.setLyrics(value, generation: generation)
                    self.refreshLine()
                case .noMatch: self.statusText = "未找到匹配歌词，可导入本地 LRC"
                case .unavailable: self.statusText = "匹配记录暂无可用歌词，可导入本地 LRC"
                }
            } catch {
                guard let self, !Task.isCancelled, self.epoch == token,
                      self.current?.track == identity, self.trackRevision == revision else { return }
                self.lookupTask = nil
                self.statusText = "在线歌词暂不可用，可导入本地 LRC"
            }
        }
    }

    private func refreshLine() {
        lineTimer?.invalidate(); lineTimer = nil
        let now = clock()
        var selection = timeline.selection(at: now)
        // An unavailable lyric document intentionally short-circuits the pure
        // timeline. Source freshness still governs the visible song metadata.
        if let value = current {
            let age = now - value.observedAt
            if !age.isFinite || age < 0 || age >= timeline.freshnessInterval { selection = .stale }
        }
        switch selection {
        case .line(_, let cue): line = cue.text; statusText = current?.state == .paused ? "已暂停" : "同步歌词"
        case .plain(let lines): line = lines.first ?? ""; statusText = "纯文本歌词 · 未同步"
        case .instrumental: line = ""; statusText = "纯音乐"
        case .beforeFirstLine: line = ""; statusText = "等待第一句歌词"
        case .gap: line = ""; statusText = "间奏"
        case .ended: line = ""; statusText = "播放已结束"
        case .stale: line = ""; trackTitle = ""; statusText = "Music 播放信息已过期"
        case .waitingForPlayback: line = ""; statusText = "等待播放位置"
        case .unavailable:
            line = ""
            if lookupTask == nil { statusText = onlineLookupEnabled ? "暂无匹配歌词，可导入本地 LRC" : "可为当前歌曲导入 LRC 歌词" }
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
