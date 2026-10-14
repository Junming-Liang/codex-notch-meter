import XCTest
@testable import NotchCore

/// Opt-in, read-only inspection of the official signed DMG on a disposable CI runner.
/// No Codex executable is launched and no account/configuration files are accessed.
final class OfficialDesktopArtifactTests: XCTestCase {
    func testOfficialMountedDesktopResolvesWithinProductionDeadline() async throws {
        #if os(macOS)
        guard let path = ProcessInfo.processInfo.environment["CODEX_TEST_OFFICIAL_APP"] else {
            throw XCTSkip("Official artifact inspection runs in its separate CI job")
        }
        let application = URL(fileURLWithPath: path, isDirectory: true)
        let started = ProcessInfo.processInfo.systemUptime
        let helper: URL
        do {
            helper = try await CodexExecutable.resolveInstalled(override: path, environment: ["PATH": ""])
        } catch {
            // Keep the original production failure. Let this SAME read-only worker
            // emit its stage timings under a finite diagnostic window; never retry
            // validation against a warmed cache and never start a Codex process.
            print("OFFICIAL_DIAGNOSTIC: production resolver failed; observing its existing worker for at most 20 seconds")
            try await Task.sleep(nanoseconds: 20_000_000_000)
            throw error
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        // The production deadline is 6s; allow 0.5s for CI continuation scheduling.
        XCTAssertLessThanOrEqual(elapsed, 6.5)
        XCTAssertTrue(DesktopCodexDiscovery.contained(helper, in: application))
        XCTAssertTrue(DesktopCodexDiscovery.isRegularExecutable(helper))
        let relative = String(helper.path.dropFirst(application.resolvingSymlinksInPath().path.count + 1))
        XCTAssertTrue(DesktopCodexDiscovery.helperPaths.contains(relative))
        print("OFFICIAL_DISCOVERY_OK: verified bundled helper \(relative); elapsed \(elapsed) seconds; never executed")
        #else
        throw XCTSkip("macOS signature inspection required")
        #endif
    }
}
