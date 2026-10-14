#if os(macOS)
import AppKit

enum SmokeDiagnostics {
    static func mark(_ stage: String) {
        guard CommandLine.arguments.contains("--smoke-test") else { return }
        // Fixed stage labels only: never arguments, paths, account data, or environment values.
        FileHandle.standardError.write(Data("SMOKE_STAGE: \(stage)\n".utf8))
    }
}

@main
struct CodexNotchMeterMain {
    @MainActor static func main() {
        SmokeDiagnostics.mark("main entered")
        let application = NSApplication.shared
        SmokeDiagnostics.mark("NSApplication created")
        let delegate = AppController()
        SmokeDiagnostics.mark("delegate created")
        application.delegate = delegate
        SmokeDiagnostics.mark("entering application run loop")
        withExtendedLifetime(delegate) { application.run() }
        SmokeDiagnostics.mark("application run loop returned")
    }
}
#else
import Foundation
@main
struct UnsupportedPlatformMain {
    static func main() { print("Codex Notch Meter is a native macOS app. Core tests can run on other platforms.") }
}
#endif
