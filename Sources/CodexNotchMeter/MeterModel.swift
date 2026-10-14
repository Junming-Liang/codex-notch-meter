#if os(macOS)
import AppKit
import Combine
import NotchCore

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var error: MeterError?
    @Published private(set) var refreshing = false
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
    private var sleeping = false
    let demo: Bool

    init(demo: Bool) {
        self.demo = demo
        overlayEnabled = defaults.object(forKey: "overlayEnabled") as? Bool ?? true
        preferredBucket = defaults.string(forKey: "preferredBucket") ?? "codex"
        executablePath = defaults.string(forKey: "executablePath") ?? ""
        if demo {
            snapshot = QuotaSnapshot(buckets: [QuotaBucket(id: "codex", name: "Codex · Demo", windows: [
                QuotaWindow(id: "codex:primary", usedPercent: 28, durationMinutes: 300, resetsAt: Date().addingTimeInterval(8160)),
                QuotaWindow(id: "codex:secondary", usedPercent: 46, durationMinutes: 10080, resetsAt: Date().addingTimeInterval(304200))
            ])], fetchedAt: Date())
        }
    }
    var bucket: QuotaBucket? { snapshot?.bucket(preferredID: preferredBucket) }
    var stale: Bool { !demo && (snapshot?.isStale(at: now) ?? false) }
    var degraded: Bool { stale || error != nil }
    var status: String {
        if demo { return "演示数据 · 未启动 Codex 进程" }
        if let error {
            switch error {
            case .codexMissing, .invalidExecutable: return "未找到可用的 Codex CLI，请在设置中选择官方可执行文件。"
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
                let executable = try CodexExecutable.resolve(override: path)
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
}
#endif
