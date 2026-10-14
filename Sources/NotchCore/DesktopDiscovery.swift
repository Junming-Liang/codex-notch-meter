import Foundation
#if os(macOS)
import CoreServices
import Security
#endif

/// Reads only installed application metadata and known bundled executable locations.
/// It never opens Codex account, configuration, credential, or conversation files.
public enum DesktopCodexDiscovery {
    static let bundleIdentifier = "com.openai.codex"
    static let teamIdentifier = "2DC432GLL2"
    static let helperPaths = [
        "Contents/Resources/codex-cli/bin/codex",
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex"
    ]
    private static func boundedData(_ url: URL, in root: URL, maximum: Int) -> Data? {
        guard contained(url, in: root),
              let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximum else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
        return data
    }
    private static func validPackage(in root: URL) -> Bool {
        let package = root.appendingPathComponent("Contents/Resources/codex-cli", isDirectory: true)
        guard let data = boundedData(package.appendingPathComponent("codex-package.json"), in: root, maximum: 16_384),
              let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["layoutVersion"] as? Int == 1,
              metadata["variant"] as? String == "codex",
              metadata["entrypoint"] as? String == "bin/codex",
              metadata["resourcesDir"] as? String == "codex-resources",
              metadata["pathDir"] as? String == "codex-path",
              let version = metadata["version"] as? String, !version.isEmpty,
              let target = metadata["target"] as? String,
              ["aarch64-apple-darwin", "x86_64-apple-darwin"].contains(target) else { return false }
        return true
    }
    static func isRegularExecutable(_ url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath()
        return (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: canonical.path)
    }
    static func contained(_ url: URL, in root: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }
    /// Signature verdict injection is only used by structural synthetic unit fixtures.
    static func helper(in application: URL, verify: (URL, Bool) -> Bool) -> URL? {
        let root = application.resolvingSymlinksInPath()
        guard root.pathExtension == "app",
              let data = boundedData(root.appendingPathComponent("Contents/Info.plist"), in: root, maximum: 65_536),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty,
              verify(root, true) else { return nil }
        let packageValid = validPackage(in: root)
        for path in helperPaths {
            if path.contains("/codex-cli/") && !packageValid { continue }
            let candidate = root.appendingPathComponent(path)
            guard contained(candidate, in: root), isRegularExecutable(candidate), verify(candidate, false) else { continue }
            // Use the signed Mach-O directly, avoiding a shell launcher and its PATH assumptions.
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }
    static func candidateApplications(registered: [URL], roots: [URL]) -> [URL] {
        var candidates = registered
        for root in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            candidates += entries.filter { $0.pathExtension == "app" }.sorted { $0.path < $1.path }.prefix(512)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }
    #if os(macOS)
    static func verifySignature(_ url: URL, application: Bool) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        if application { text += " and identifier \"\(bundleIdentifier)\"" }
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures | (application ? kSecCSCheckNestedCode : 0)
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), requirement) == errSecSuccess
    }
    static func installed() -> URL? {
        let registered = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        for app in candidateApplications(registered: registered, roots: roots) {
            if let helper = helper(in: app, verify: { verifySignature($0, application: $1) }) { return helper }
        }
        return nil
    }
    #else
    static func installed() -> URL? { nil }
    #endif
}
