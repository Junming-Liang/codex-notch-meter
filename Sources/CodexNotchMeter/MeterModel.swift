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
        if demo { return "Demo data · no Codex process is running" }
        if let error { return error.localizedDescription }
        if refreshing && snapshot == nil { return "Reading Codex account…" }
        if stale { return "Last reading is stale. Waiting for a fresh quota check." }
        if snapshot == nil { return "No quota reading yet" }
        return "Read-only Codex account check"
    }
    var compactLabel: String {
        let values = (bucket?.windows ?? []).prefix(2).map { window in
            window.remainingPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        }
        let content = values.isEmpty ? "—" : values.joined(separator: " · ")
        return (demo ? "DEMO " : degraded ? "◷ " : "") + content
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
        guard !demo, !refreshing, !sleeping else { return }
        refreshing = true
        lastAttempt = Date()
        let path = executablePath
        task = Task { [weak self] in
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
            refreshing = false; now = Date(); nextAttempt = now.addingTimeInterval(policy.delay); task = nil
        }
    }
    func sleep() {
        sleeping = true; task?.cancel(); task = nil; refreshing = false
    }
    func wake() { sleeping = false; refresh() }
    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); task = nil }
    func setExecutable(_ path: String) {
        task?.cancel(); task = nil; refreshing = false
        executablePath = path; snapshot = nil; error = nil; nextAttempt = .distantPast
        refresh()
    }
}
#endif
