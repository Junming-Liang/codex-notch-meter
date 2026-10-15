import XCTest
@testable import NotchCore

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var registerResult: LoginItemStatus = .enabled
    var removalResult: LoginItemStatus = .notRegistered
    var failRegister = false, failRemoval = false
    var registrations = 0, removals = 0, settingsOpened = 0
    func register() throws { registrations += 1; status = registerResult; if failRegister { throw CocoaError(.fileWriteNoPermission) } }
    func unregister() throws { removals += 1; status = removalResult; if failRemoval { throw CocoaError(.fileWriteNoPermission) } }
    func openSettings() { settingsOpened += 1 }
}

final class LoginItemTests: XCTestCase {
    @MainActor func testInitializationAndRefreshNeverMutateSystem() async {
        let service = FakeLoginService()
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { .applications })
        controller.refresh(); service.status = .enabled; controller.refresh()
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registrations + service.removals + service.settingsOpened, 0)
    }
    @MainActor func testExplicitEnableDisableReadBackSystemState() async {
        let service = FakeLoginService()
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { .applications })
        controller.setEnabledByUser(true); XCTAssertEqual(controller.status, .enabled)
        controller.setEnabledByUser(true); XCTAssertEqual(service.registrations, 1)
        controller.setEnabledByUser(false); XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(service.removals, 1); XCTAssertEqual(service.settingsOpened, 0)
    }
    @MainActor func testPendingApprovalDoesNotReregisterAndCanBeCancelled() async {
        let service = FakeLoginService(); service.registerResult = .requiresApproval
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { .applications })
        controller.setEnabledByUser(true); controller.setEnabledByUser(true)
        XCTAssertEqual(controller.status, .requiresApproval); XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(service.settingsOpened, 0)
        controller.openSettingsByUser(); XCTAssertEqual(service.settingsOpened, 1)
        controller.setEnabledByUser(false); XCTAssertEqual(controller.status, .notRegistered)
    }
    @MainActor func testExternalRevocationAndFailedRemovalNeverInventSuccess() async {
        let service = FakeLoginService(); service.status = .enabled
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { .applications })
        service.status = .requiresApproval; controller.refresh()
        XCTAssertEqual(controller.status, .requiresApproval)
        service.failRemoval = true; service.removalResult = .requiresApproval
        controller.setEnabledByUser(false)
        XCTAssertEqual(controller.status, .requiresApproval); XCTAssertEqual(controller.issue, .removalFailed)
    }
    @MainActor func testRegistrationFailureReadsActualStatusWithoutAutoOpeningSettings() async {
        let service = FakeLoginService(); service.failRegister = true; service.registerResult = .requiresApproval
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { .applications })
        controller.setEnabledByUser(true)
        XCTAssertEqual(controller.status, .requiresApproval); XCTAssertEqual(controller.issue, .registrationFailed)
        XCTAssertEqual(service.settingsOpened, 0)
    }
    @MainActor func testDemoBlocksEveryMutationIncludingSettingsLaunch() async {
        let service = FakeLoginService(); service.status = .enabled
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: false, installation: { .applications })
        controller.setEnabledByUser(true); controller.setEnabledByUser(false); controller.openSettingsByUser()
        XCTAssertEqual(service.registrations + service.removals + service.settingsOpened, 0)
        XCTAssertEqual(controller.issue, .disabledInDemo)
    }
    @MainActor func testUnsafeLocationsCannotEnrollAndAreRecheckedAtClickTime() async {
        for location in [AppInstallLocation.downloads, .readOnlyVolume, .translocated, .other, .unbundled] {
            let service = FakeLoginService(); var current = AppInstallLocation.applications
            let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { current })
            current = location; controller.setEnabledByUser(true)
            XCTAssertEqual(service.registrations, 0); XCTAssertEqual(controller.issue, .installFirst)
        }
    }
    @MainActor func testRemovalStillAvailableAfterAppMoved() async {
        let service = FakeLoginService(); service.status = .enabled
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { .downloads })
        controller.setEnabledByUser(false); XCTAssertEqual(service.removals, 1)
    }
    @MainActor func testUnknownSystemStatusFailsClosed() async {
        let service = FakeLoginService(); service.status = .unavailable
        let controller = LoginItemCoordinator(service: service, mutationsAllowed: true, installation: { .applications })
        controller.setEnabledByUser(true)
        XCTAssertEqual(service.registrations, 0); XCTAssertEqual(controller.issue, .registrationFailed)
        XCTAssertEqual(controller.status, .unavailable)
    }
    func testInstallClassificationUsesCanonicalBoundariesAndVolumeState() {
        let home = URL(fileURLWithPath: "/tmp/synthetic-home")
        func classify(_ path: String, canonical: String? = nil, readOnly: Bool = false) -> AppInstallLocation {
            AppInstallLocation.assess(original: URL(fileURLWithPath: path), canonical: URL(fileURLWithPath: canonical ?? path), home: home, readOnly: readOnly)
        }
        XCTAssertEqual(classify("/Applications/Meter.app"), .applications)
        XCTAssertEqual(classify("/tmp/synthetic-home/Applications/Meter.app"), .applications)
        XCTAssertEqual(classify("/Applications-Other/Meter.app"), .other)
        XCTAssertEqual(classify("/Applications/Meter.app", canonical: "/tmp/synthetic-home/Downloads/Meter.app"), .downloads)
        XCTAssertEqual(classify("/Volumes/Installer/Meter.app", readOnly: true), .readOnlyVolume)
        XCTAssertEqual(classify("/tmp/AppTranslocation/Example/d/Meter.app"), .translocated)
        XCTAssertEqual(classify("/tmp/Meter"), .unbundled)
    }
    func testThemeRestorationDefaultsSafely() {
        XCTAssertEqual(MeterTheme.restored(nil), .standard)
        XCTAssertEqual(MeterTheme.restored("invalid"), .standard)
        XCTAssertEqual(MeterTheme.restored("rainbow"), .rainbow)
        XCTAssertEqual(MeterTheme.restored("standard"), .standard)
    }
}
