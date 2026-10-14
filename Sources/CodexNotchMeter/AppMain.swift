#if os(macOS)
import AppKit

@main
struct CodexNotchMeterMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
#else
import Foundation
@main
struct UnsupportedPlatformMain {
    static func main() { print("Codex Notch Meter is a native macOS app. Core tests can run on other platforms.") }
}
#endif
