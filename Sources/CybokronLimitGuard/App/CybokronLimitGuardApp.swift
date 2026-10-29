import AppKit
import LimitGuardCore

@main
enum CybokronLimitGuardApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication holds its delegate weakly; keep ours alive for as long as the app runs.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
