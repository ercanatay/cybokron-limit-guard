import AppKit
import LimitGuardCore

/// The legal notice (spec §4.3.1), shown as a modal window.
@MainActor
enum LegalNoticeWindow {
    enum Mode {
        /// Before anything automatic can run: the owner accepts or quits.
        case acceptance
        /// Reading it again from About or Settings.
        case review
    }

    /// Runs the window modally. Returns true when the owner chose "I understand" (always in `.review`).
    @discardableResult
    static func show(mode: Mode) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Notice.title
        alert.informativeText = L10n.Notice.body
        switch mode {
        case .acceptance:
            alert.addButton(withTitle: L10n.Notice.understand)
            alert.addButton(withTitle: L10n.Notice.quit)
            return alert.runModal() == .alertFirstButtonReturn
        case .review:
            alert.addButton(withTitle: L10n.Common.close)
            alert.runModal()
            return true
        }
    }

    /// At launch: when the current notice version hasn't been accepted, ask; "I understand" stores the
    /// version and the date, "Quit" ends the app.
    /// Returns false when the owner chose "Quit" (the app is then terminating).
    @discardableResult
    static func runAtLaunch(store: JSONStore<Settings>) -> Bool {
        let loaded = Result { try store.load() }
        var settings = (try? loaded.get()) ?? Settings()
        guard Notice.mustShow(settings: settings) else { return true }
        guard show(mode: .acceptance) else {
            NSApp.terminate(nil)
            return false
        }
        settings.noticeAcceptedVersion = Notice.currentVersion
        settings.noticeAcceptedAt = Date()
        // A settings file written by a newer app is left alone.
        if case .success = loaded { try? store.save(settings) }
        return true
    }
}
