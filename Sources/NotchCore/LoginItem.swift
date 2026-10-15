import Foundation

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound, unavailable
}

public enum AppInstallLocation: Equatable, Sendable {
    case applications, downloads, readOnlyVolume, translocated, other, unbundled
    public static func assess(original: URL, canonical: URL, home: URL, readOnly: Bool) -> Self {
        guard original.pathExtension.lowercased() == "app" else { return .unbundled }
        if original.pathComponents.contains("AppTranslocation") { return .translocated }
        if readOnly { return .readOnlyVolume }
        let path = canonical.standardizedFileURL.pathComponents
        let homePath = home.standardizedFileURL.pathComponents
        func inside(_ directory: [String]) -> Bool { path.count > directory.count && Array(path.prefix(directory.count)) == directory }
        if inside(["/", "Applications"]) || inside(homePath + ["Applications"]) { return .applications }
        if inside(homePath + ["Downloads"]) { return .downloads }
        return .other
    }
}

@MainActor
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

public enum LoginItemIssue: Equatable, Sendable {
    case installFirst, disabledInDemo, registrationFailed, removalFailed
}

/// Only explicit user actions mutate registration. Refresh never repairs or re-registers it.
@MainActor
public final class LoginItemCoordinator {
    private let service: LoginItemService
    private let installation: () -> AppInstallLocation
    public let mutationsAllowed: Bool
    public private(set) var status: LoginItemStatus = .notRegistered
    public private(set) var location: AppInstallLocation = .unbundled
    public private(set) var issue: LoginItemIssue?
    public init(service: LoginItemService, mutationsAllowed: Bool, installation: @escaping () -> AppInstallLocation) {
        self.service = service; self.mutationsAllowed = mutationsAllowed; self.installation = installation
        refresh()
    }
    public func refresh() { status = service.status; location = installation() }
    public func setEnabledByUser(_ enabled: Bool) {
        refresh(); issue = nil
        guard mutationsAllowed else { issue = .disabledInDemo; return }
        if enabled {
            guard location == .applications else { issue = .installFirst; return }
            guard status != .unavailable else { issue = .registrationFailed; return }
            // An enrollment waiting on the user's approval must not be registered again.
            guard status != .enabled && status != .requiresApproval else { return }
            do { try service.register() } catch { issue = .registrationFailed }
        } else if status == .enabled || status == .requiresApproval || status == .notFound {
            do { try service.unregister() } catch { issue = .removalFailed }
        }
        refresh()
    }
    public func openSettingsByUser() {
        guard mutationsAllowed else { issue = .disabledInDemo; return }
        service.openSettings()
    }
}
