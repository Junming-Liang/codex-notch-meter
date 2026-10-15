#if os(macOS)
import AppKit
import Combine
import ServiceManagement
import NotchCore

/// The framework's main-app login item only; no helper, daemon or hand-written launch plist.
@MainActor
private final class SystemLoginItemService: LoginItemService {
    let allowMutations: Bool
    init(allowMutations: Bool) { self.allowMutations = allowMutations }
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unavailable
        }
    }
    func register() throws {
        guard allowMutations else { throw CocoaError(.userCancelled) }
        try SMAppService.mainApp.register()
    }
    func unregister() throws {
        guard allowMutations else { throw CocoaError(.userCancelled) }
        try SMAppService.mainApp.unregister()
    }
    func openSettings() {
        guard allowMutations else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Synthetic UI states only. Never forwards to ServiceManagement.
@MainActor
private final class SyntheticLoginItemService: LoginItemService {
    var status: LoginItemStatus
    private(set) var mutationAttempts = 0
    init() {
        status = CommandLine.arguments.contains("--smoke-many") ? .requiresApproval
            : CommandLine.arguments.contains("--smoke-empty") ? .enabled : .notRegistered
    }
    func register() throws { mutationAttempts += 1; throw CocoaError(.userCancelled) }
    func unregister() throws { mutationAttempts += 1; throw CocoaError(.userCancelled) }
    func openSettings() { mutationAttempts += 1 }
}

@MainActor
final class LoginSettingsModel: ObservableObject {
    @Published private(set) var status: LoginItemStatus = .notRegistered
    @Published private(set) var location: AppInstallLocation = .unbundled
    @Published private(set) var issue: LoginItemIssue?
    private let coordinator: LoginItemCoordinator
    private let syntheticService: SyntheticLoginItemService?
    let synthetic: Bool
    init(synthetic: Bool) {
        self.synthetic = synthetic
        let fixture = synthetic ? SyntheticLoginItemService() : nil
        syntheticService = fixture
        let service: LoginItemService
        if let fixture { service = fixture } else { service = SystemLoginItemService(allowMutations: true) }
        coordinator = LoginItemCoordinator(service: service,
            mutationsAllowed: !synthetic, installation: {
                if synthetic { return CommandLine.arguments.contains("--smoke-empty") ? .downloads : .applications }
                let original = Bundle.main.bundleURL
                let canonical = original.resolvingSymlinksInPath().standardizedFileURL
                guard let values = try? canonical.resourceValues(forKeys: [.volumeIsReadOnlyKey]) else { return .other }
                return AppInstallLocation.assess(original: original, canonical: canonical,
                    home: FileManager.default.homeDirectoryForCurrentUser, readOnly: values.volumeIsReadOnly ?? true)
            })
        refresh()
    }
    var isEnabled: Bool { status == .enabled }
    var canEnable: Bool { !synthetic && location == .applications }
    var needsApproval: Bool { status == .requiresApproval }
    var locationAdvice: String? {
        switch location {
        case .applications: return nil
        case .downloads: return "请先退出应用，将它从“下载”拖入“应用程序”，再从“应用程序”重新打开。"
        case .readOnlyVolume: return "当前从只读卷或安装映像运行。请先将应用拖入“应用程序”，退出后从那里重新打开。"
        case .translocated: return "当前运行的是系统隔离位置中的副本。请先退出，将应用放入“应用程序”，再重新打开。"
        case .other, .unbundled: return "请将完整的 .app 放入“应用程序”（或个人 Applications 文件夹），再启用登录时启动。"
        }
    }
    var statusText: String {
        if synthetic { return "演示数据 · 不更改系统登录项。" + systemStatusText }
        if location != .applications { return locationAdvice ?? "请先安装到“应用程序”。" }
        if (issue == .registrationFailed && status == .enabled) || (issue == .removalFailed && status == .notRegistered) {
            return systemStatusText
        }
        if let issue {
            switch issue {
            case .installFirst: return locationAdvice ?? "请先安装到“应用程序”。"
            case .disabledInDemo: return "演示模式不更改登录项。"
            case .registrationFailed: return "系统未完成启用请求。请检查下方实际状态与系统登录项；临时签名可能不被系统接受。"
            case .removalFailed: return "系统未完成停用请求。请在系统登录项中检查，应用不会将失败显示为已关闭。"
            }
        }
        return systemStatusText
    }
    var systemStatusText: String {
        switch status {
        case .enabled: return "已启用：登录此 Mac 账户时启动。"
        case .requiresApproval: return "等待系统批准：尚不能保证登录时启动。"
        case .notRegistered: return "未启用。只有你打开此开关后才会请求注册。"
        case .notFound: return "系统未找到登录项。可检查安装位置或系统设置。"
        case .unavailable: return "系统未提供可识别的登录项状态。"
        }
    }
    func verifySyntheticSafety() -> Bool {
        guard synthetic, let service = syntheticService else { return false }
        coordinator.setEnabledByUser(true); coordinator.setEnabledByUser(false); coordinator.openSettingsByUser()
        refresh()
        let actual = SystemLoginItemService(allowMutations: false).status
        SmokeDiagnostics.mark("login system API read-only actualStatus=\(actual); registration disabled")
        let valid = service.mutationAttempts == 0 && !canEnable
        SmokeDiagnostics.mark("login settings synthetic state=\(status) location=\(location) mutationCalls=\(service.mutationAttempts) valid=\(valid)")
        return valid
    }
    func refresh() {
        coordinator.refresh(); publish()
    }
    func setEnabled(_ enabled: Bool) { coordinator.setEnabledByUser(enabled); publish() }
    func cancelPending() { coordinator.setEnabledByUser(false); publish() }
    func openSettings() { coordinator.openSettingsByUser(); publish() }
    private func publish() { status = coordinator.status; location = coordinator.location; issue = coordinator.issue }
}
#endif
