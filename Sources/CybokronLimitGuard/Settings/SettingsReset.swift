import AppKit
import LimitGuardCore
import OSLog

/// "Reset settings…" for an unreadable `settings.json` (from the Settings banner or the popover).
@MainActor
enum SettingsReset {
    private static let logger = Logger(subsystem: "com.cybokron.limitguard", category: "settings")

    /// Confirms, keeps the broken file as `settings.corrupt-<timestamp>.json`, writes the defaults and
    /// then asks for the legal notice again, because the defaults have not accepted it. Returns true
    /// when the file was reset.
    @discardableResult
    static func run(store: JSONStore<Settings>) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Settings.Reset.title
        alert.informativeText = L10n.Settings.Reset.message
        alert.addButton(withTitle: L10n.Settings.Reset.confirm)
        alert.addButton(withTitle: L10n.Common.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let backup = try SettingsRecovery.resetUnreadable(store: store)
            logger.notice("unreadable settings kept as \(backup.lastPathComponent, privacy: .public); defaults written")
        } catch {
            logger.error("settings not reset: \(String(describing: error), privacy: .public)")
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = L10n.Settings.Reset.failed(error.localizedDescription)
            failed.addButton(withTitle: L10n.Common.close)
            failed.runModal()
            return false
        }
        // As at first launch: "Quit" ends the app, "I understand" is saved into the new file.
        guard LegalNoticeWindow.runAtLaunch(store: store) else { return true }
        NotificationCenter.default.post(name: .limitGuardSettingsChanged, object: nil)
        return true
    }
}
