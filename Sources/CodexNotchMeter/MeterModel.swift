#if os(macOS)
import AppKit
import Combine
import NotchCore

struct CalibrationDisplay: Identifiable, Equatable {
    let id: String
    let name: String
    var minimum: Double = -8
    var maximum: Double = 8
}

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var error: MeterError?
    @Published private(set) var refreshing = false
    @Published var displayNotice: String?
    @Published var theme: MeterTheme { didSet { if !demo { defaults.set(theme.rawValue, forKey: "theme") } } }
    @Published var skinMotionEnabled: Bool { didSet { if !demo { defaults.set(skinMotionEnabled, forKey: "skinMotionEnabled") } } }
    @Published var skinSpeed: SkinMotionSpeed { didSet { if !demo { defaults.set(skinSpeed.rawValue, forKey: "skinSpeed") } } }
    @Published var preferredQuota: String { didSet { if !demo { defaults.set(preferredQuota, forKey: "preferredQuota") } } }
    @Published private(set) var skinPhase: Double = 0
    @Published private(set) var calibrationDisplays: [CalibrationDisplay] = []
    @Published var selectedCalibrationDisplayID = ""
    @Published private(set) var horizontalCalibrations: [String: Double] = [:] {
        didSet { if !demo { defaults.set(horizontalCalibrations, forKey: "horizontalCalibrations") } }
    }
    @Published private(set) var now = Date()
    @Published var overlayEnabled: Bool { didSet { defaults.set(overlayEnabled, forKey: "overlayEnabled") } }
    @Published var preferredBucket: String { didSet { defaults.set(preferredBucket, forKey: "preferredBucket") } }
    @Published var executablePath: String { didSet { defaults.set(executablePath, forKey: "executablePath") } }
    private let defaults = UserDefaults.standard
    private var policy = RefreshPolicy()
    private var nextAttempt = Date.distantPast
    private var lastAttempt: Date?
    private var task: Task<Void, Never>?
    private var currentTaskID: UUID?
    private var outstandingTasks: [UUID: Task<Void, Never>] = [:]
    private var shuttingDown = false
    private var timer: Timer?
    private lazy var skinAnimator = SkinAnimator { [weak self] in self?.skinPhase = $0 }
    private var sleeping = false
    let demo: Bool

    init(demo: Bool) {
        self.demo = demo
        let fixtureTheme = CommandLine.arguments.first(where: { $0.hasPrefix("--skin=") }).map { String($0.dropFirst(7)) }
        theme = demo ? MeterTheme.restored(fixtureTheme ?? (CommandLine.arguments.contains("--rainbow") ? "rainbow" : nil)) : MeterTheme.restored(defaults.string(forKey: "theme"))
        skinMotionEnabled = demo ? true : defaults.object(forKey: "skinMotionEnabled") as? Bool ?? true
        skinSpeed = demo ? .normal : SkinMotionSpeed.restored(defaults.string(forKey: "skinSpeed"))
        preferredQuota = demo ? "" : defaults.string(forKey: "preferredQuota") ?? ""
        overlayEnabled = defaults.object(forKey: "overlayEnabled") as? Bool ?? true
        preferredBucket = defaults.string(forKey: "preferredBucket") ?? "codex"
        executablePath = defaults.string(forKey: "executablePath") ?? ""
        if !demo, let saved = defaults.dictionary(forKey: "horizontalCalibrations") {
            horizontalCalibrations = saved.reduce(into: [:]) { result, entry in
                if !entry.key.isEmpty, entry.key.count <= 64, let value = entry.value as? Double {
                    result[entry.key] = HorizontalCalibration.sanitized(value)
                }
            }
        }
        if demo {
            snapshot = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Codex · Demo", windows: [
                QuotaWindow(id: "codex:primary", usedPercent: 28, durationMinutes: 300, resetsAt: Date().addingTimeInterval(8160)),
                QuotaWindow(id: "codex:secondary", usedPercent: 46, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(304200))
            ])], fetchedAt: Date())
            if CommandLine.arguments.contains("--smoke-empty") { snapshot = nil; error = .codexMissing }
            if CommandLine.arguments.contains("--smoke-many") {
                snapshot = QuotaSnapshot(buckets: (0..<4).map { index in
                    QuotaBucket(id: "synthetic-\(index)", name: "演示额度组 \(index + 1)", windows: [
                        QuotaWindow(id: "\(index)-short", usedPercent: 28, durationMinutes: 300, resetsAt: Date().addingTimeInterval(8160)),
                        QuotaWindow(id: "\(index)-long", usedPercent: 46, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(304200))
                    ])
                }, fetchedAt: Date())
            }
        }
    }
    func configureCalibrationDisplays(_ displays: [CalibrationDisplay]) {
        if calibrationDisplays != displays { calibrationDisplays = displays }
        if !displays.contains(where: { $0.id == selectedCalibrationDisplayID }) {
            selectedCalibrationDisplayID = displays.first?.id ?? ""
        }
    }
    func horizontalAdjustment(for displayID: String?) -> Double {
        guard let displayID else { return 0 }
        let requested = HorizontalCalibration.sanitized(horizontalCalibrations[displayID] ?? 0)
        guard let display = calibrationDisplays.first(where: { $0.id == displayID }) else { return requested }
        return min(display.maximum, max(display.minimum, requested))
    }
    var selectedCalibrationDisplay: CalibrationDisplay? { calibrationDisplays.first { $0.id == selectedCalibrationDisplayID } }
    var selectedHorizontalAdjustment: Double { horizontalAdjustment(for: selectedCalibrationDisplayID) }
    var hasStoredHorizontalAdjustment: Bool { horizontalCalibrations[selectedCalibrationDisplayID] != nil }
    func setHorizontalAdjustment(_ value: Double) {
        let key = selectedCalibrationDisplayID
        guard calibrationDisplays.contains(where: { $0.id == key }) else { return }
        guard let display = selectedCalibrationDisplay else { return }
        let value = min(display.maximum, max(display.minimum, HorizontalCalibration.sanitized(value)))
        // Reset must clear a saved correction even when current bounds clamp its visible value to zero.
        if value == 0 {
            if horizontalCalibrations[key] != nil { horizontalCalibrations.removeValue(forKey: key) }
            return
        }
        guard horizontalAdjustment(for: key) != value else { return }
        horizontalCalibrations[key] = value
    }
    var bucket: QuotaBucket? { snapshot?.bucket(preferredID: preferredBucket) }
    var primaryWindow: QuotaWindow? { bucket?.primaryWindow(preferredID: preferredQuota) }
    /// One clock shared by every visible contour/card. Never drives quota polling.
    func updateSkinActivity(_ policy: SkinMotionPolicy) {
        // Synthetic fixed-phase captures own their phase. Lifecycle reads must not overwrite it.
        guard !demo, !shuttingDown else { skinAnimator.stop(); return }
        skinAnimator.set(policy: policy, speed: skinSpeed)
    }
    func setSkinPhaseForTesting(_ phase: Double) {
        guard demo, CommandLine.arguments.contains("--contour-test") || CommandLine.arguments.contains("--motion-test"), phase.isFinite else { return }
        skinPhase = min(0.999999, max(0, phase))
    }
    var stale: Bool { (!demo || CommandLine.arguments.contains("--contour-test")) && (snapshot?.isStale(at: now) ?? false) }
    var degraded: Bool { stale || error != nil }
    var status: String {
        if let error {
            switch error {
            case .codexMissing, .invalidExecutable: return "未找到受支持的 Codex 应用或 CLI，请在设置中选择已安装的官方应用。"
            case .signedOut: return "请先在 Codex 中使用 ChatGPT 账户登录，再刷新额度。"
            case .unsupportedAccount: return "当前账户不提供订阅额度窗口，API Key 计费暂不支持。"
            case .noQuota: return "Codex 暂未提供额度窗口，缺失数据不会被当作满额。"
            case .malformedResponse, .incompatibleVersion: return "Codex 接口暂不兼容，请检查官方 CLI 版本。"
            case .timedOut, .disconnected: return "读取未完成，请检查连接后重试。已有数字是上次读取结果。"
            case .protocolLimit: return "响应超过安全限制，已关闭本次连接。"
            case .launchFailed: return "无法启动 Codex CLI，请检查设置中的可执行文件。"
            case .cancelled: return "本次刷新已取消。"
            case .serverError(let code): return "Codex 额度读取失败（\(code)），请检查网络或登录状态。"
            }
        }
        if demo { return "演示数据 · 未启动 Codex 进程" }
        if refreshing && snapshot == nil { return "正在读取 Codex 账户…" }
        if stale { return "数据已过期，正在等待新的额度读取。" }
        if snapshot == nil { return "尚未读取额度" }
        return "只读同步 · 每 60 秒刷新"
    }
    var compactLabel: String {
        let values = (bucket?.windows ?? []).prefix(2).map { window in
            window.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        }
        let content = values.isEmpty ? "—" : values.joined(separator: " · ")
        return (demo ? "演示 " : degraded ? "◷ " : "") + content
    }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh()
    }
    private func tick() {
        now = Date()
        guard !sleeping, !demo, !refreshing, now >= nextAttempt else { return }
        refresh()
    }
    func hover() {
        guard RefreshPolicy.shouldRefreshOnHover(lastAttempt: lastAttempt, now: Date()) else { return }
        // Hover never overrides error backoff. Manual refresh and wake may do so.
        if error == nil || Date() >= nextAttempt { refresh() }
    }
    func refresh() {
        guard !demo, !refreshing, !sleeping, !shuttingDown else { return }
        refreshing = true
        lastAttempt = Date()
        let path = executablePath
        let id = UUID()
        currentTaskID = id
        let newTask = Task { [weak self] in
            defer {
                self?.outstandingTasks[id] = nil
                if self?.currentTaskID == id { self?.task = nil; self?.currentTaskID = nil }
            }
            do {
                let executable = try await CodexExecutable.resolveInstalled(override: path)
                try Task.checkCancellation()
                let result = try await QuotaReader.fetch(executable: executable)
                guard !Task.isCancelled, let self else { return }
                snapshot = result; error = nil; policy.succeeded()
            } catch {
                guard !Task.isCancelled, let self else { return }
                let failure = error as? MeterError ?? .disconnected
                self.error = failure
                // Never show another account's prior numbers after sign-out or account-type change.
                if [.signedOut, .unsupportedAccount, .noQuota, .codexMissing, .invalidExecutable].contains(failure) { snapshot = nil }
                policy.failed()
            }
            guard let self else { return }
            refreshing = false; now = Date(); nextAttempt = now.addingTimeInterval(policy.delay)
        }
        task = newTask
        outstandingTasks[id] = newTask
    }
    func sleep() {
        sleeping = true; task?.cancel(); task = nil; refreshing = false
    }
    func wake() { sleeping = false; refresh() }
    func stop() {
        timer?.invalidate(); timer = nil
        skinAnimator.stop()
        for pending in outstandingTasks.values { pending.cancel() }
    }
    func shutdown() async {
        shuttingDown = true
        stop()
        // Includes reads retired by sleep or executable changes, not only the newest task.
        let pending = Array(outstandingTasks.values)
        for task in pending { await task.value }
        task = nil; currentTaskID = nil
    }
    func setExecutable(_ path: String) {
        task?.cancel(); task = nil; refreshing = false
        executablePath = path; snapshot = nil; error = nil; nextAttempt = .distantPast
        refresh()
    }
    /// Bounded many-row UI load for native timing only. No account reads or preference writes.
    func setMotionFixture(remaining: Double) {
        guard demo, CommandLine.arguments.contains("--motion-test") else { return }
        now = Date(); error = nil
        snapshot = QuotaSnapshot(buckets: (0..<4).map { index in
            QuotaBucket(id: "synthetic-\(index)", name: "演示额度组 \(index + 1)", windows: [
                QuotaWindow(id: "\(index)-short", usedPercent: 100 - remaining, durationMinutes: 300,
                    resetsAt: now.addingTimeInterval(8160)),
                QuotaWindow(id: "\(index)-long", usedPercent: 62, durationMinutes: 10080,
                    resetsAt: now.addingTimeInterval(304200))
            ])
        }, fetchedAt: now)
    }
    /// Synthetic rendering fixtures update the SAME live published model; never enable account I/O.
    func setContourFixture(left: Double?, right: Double?, stale: Bool = false, pending: Bool = false) {
        guard demo, CommandLine.arguments.contains("--contour-test") || CommandLine.arguments.contains("--alignment-test") || CommandLine.arguments.contains("--motion-test") else { return }
        now = Date(); error = nil
        snapshot = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Codex · Demo", windows: [left, right].enumerated().map { index, remaining in
            QuotaWindow(id: "render-\(index)", usedPercent: remaining.map { 100 - $0 },
                durationMinutes: index == 0 ? 300 : 10080,
                resetsAt: now.addingTimeInterval(pending ? -10 : 3600))
        })], fetchedAt: now.addingTimeInterval(stale ? -3600 : 0))
    }
}
#endif
