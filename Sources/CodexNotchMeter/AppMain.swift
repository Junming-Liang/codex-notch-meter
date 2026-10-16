#if os(macOS)
import AppKit

enum SmokeDiagnostics {
    static func mark(_ stage: String) {
        guard CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--contour-test") || CommandLine.arguments.contains("--alignment-test") || CommandLine.arguments.contains("--motion-test") || CommandLine.arguments.contains("--display-test") || CommandLine.arguments.contains("--collapse-test") || CommandLine.arguments.contains("--update-test") || CommandLine.arguments.contains("--music-test") else { return }
        // Smoke-only stage labels and synthetic window measurements; never account data or paths.
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
