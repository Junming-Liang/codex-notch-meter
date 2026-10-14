import XCTest
@testable import NotchCore

final class DiscoveryTests: XCTestCase {
    private func fixture(_ name: String = "Renamed Desktop.app", id: String = "com.openai.codex", helper: String = "Contents/Resources/codex") throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent(name, isDirectory: true)
        let executable = app.appendingPathComponent(helper)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic executable; never run".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "0.0.synthetic"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if helper.contains("/codex-cli/") {
            let metadata: [String: Any] = ["layoutVersion": 1, "variant": "codex", "entrypoint": "bin/codex",
                "resourcesDir": "codex-resources", "pathDir": "codex-path", "version": "0.0.synthetic", "target": "aarch64-apple-darwin"]
            try JSONSerialization.data(withJSONObject: metadata).write(to: app.appendingPathComponent("Contents/Resources/codex-cli/codex-package.json"))
        }
        return (root, app)
    }
    func testRenamedDesktopAndLegacyHelperWithSyntheticSignatureVerdict() throws {
        let (root, app) = try fixture("ChatGPT.app"); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true })?.lastPathComponent, "codex")
    }
    func testEmptyFinderPathCanResolveRegisteredRenamedDesktopFixture() throws {
        let (root, app) = try fixture("ChatGPT.app"); defer { try? FileManager.default.removeItem(at: root) }
        let result = try CodexExecutable.resolveCandidates(override: nil, environment: ["PATH": ""], desktop: {
            DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true })
        })
        XCTAssertEqual(result, app.appendingPathComponent("Contents/Resources/codex"))
    }
    func testPackagedNativeHelperWithSyntheticSignatureVerdict() throws {
        let (root, app) = try fixture(helper: "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
    }
    func testCanonicalPackageEntrypointAndManifestValidation() throws {
        let (root, app) = try fixture(helper: "Contents/Resources/codex-cli/bin/codex")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
        let metadata = app.appendingPathComponent("Contents/Resources/codex-cli/codex-package.json")
        try Data(#"{"layoutVersion":1,"entrypoint":"../../outside"}"#.utf8).write(to: metadata)
        XCTAssertNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
        try FileManager.default.removeItem(at: metadata)
        XCTAssertNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
    }
    func testWrongIdentityOrSignatureCannotResolve() throws {
        let (root, app) = try fixture(id: "synthetic.spoof"); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
        let (goodRoot, goodApp) = try fixture(); defer { try? FileManager.default.removeItem(at: goodRoot) }
        XCTAssertNil(DesktopCodexDiscovery.helper(in: goodApp, verify: { _, _ in false }))
        XCTAssertNil(DesktopCodexDiscovery.helper(in: goodApp, verify: { _, application in application }))
    }
    func testMissingHelperAndDirectoryAreRejected() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
        try FileManager.default.createDirectory(at: executable, withIntermediateDirectories: true)
        XCTAssertFalse(DesktopCodexDiscovery.isRegularExecutable(executable))
        XCTAssertNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
    }
    func testSymlinkEscapingSignedBundleIsRejected() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: executable, to: outside)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: outside)
        XCTAssertNil(DesktopCodexDiscovery.helper(in: app, verify: { _, _ in true }))
    }
    func testApplicationRootsAndRegistrationAreDeduplicated() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(DesktopCodexDiscovery.candidateApplications(registered: [app], roots: [root, root]), [app])
    }
    func testExplicitCLIOverrideStillWorksWithoutPath() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        XCTAssertEqual(try CodexExecutable.resolve(override: executable.path, environment: ["PATH": ""]), executable)
    }
    func testValidAndDanglingCLISymlinks() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        let link = root.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(try CodexExecutable.resolve(override: link.path, environment: [:]), executable)
        try FileManager.default.removeItem(at: executable)
        XCTAssertFalse(DesktopCodexDiscovery.isRegularExecutable(link))
        XCTAssertThrowsError(try CodexExecutable.resolve(override: link.path, environment: [:]))
    }
    func testResolverTimeoutDoesNotWaitForReadOnlyWorker() async throws {
        let start = Date()
        do {
            _ = try await CodexExecutable.boundedResolution(timeout: 0.03) {
                Thread.sleep(forTimeInterval: 0.4); return URL(fileURLWithPath: "/synthetic/codex")
            }
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? MeterError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }
    func testCanceledResolverCannotDelayShutdown() async throws {
        let task = Task {
            try await CodexExecutable.boundedResolution {
                Thread.sleep(forTimeInterval: 0.4); return URL(fileURLWithPath: "/synthetic/codex")
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
    }
    #if os(macOS)
    func testNativeSignatureVerificationRejectsUnsignedSyntheticBundle() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(DesktopCodexDiscovery.verifySignature(app, application: true))
        XCTAssertNil(DesktopCodexDiscovery.helper(in: app, verify: { DesktopCodexDiscovery.verifySignature($0, application: $1) }))
    }
    #endif
}
