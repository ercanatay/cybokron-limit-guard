import AppKit
import LimitGuardCore

/// Placeholder shell: a status item showing "LG" with Settings…, About and Quit, so the app
/// launches. The popover comes later.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let updater = AutoUpdater()
    private lazy var updateWindow = UpdateWindowController(updater: updater)
    private lazy var aboutWindow = AboutWindowController()
    private lazy var diagnosticsWindow = DiagnosticsWindowController()
    private let settingsStore = JSONStore<Settings>(url: AppPaths.settingsURL, schemaVersion: 1)
    private lazy var settingsWindow = SettingsWindowController(
        store: settingsStore,
        updater: updater,
        runDiagnostics: { [weak self] in self?.diagnosticsWindow.show() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater.showWindow = { [weak self] in self?.updateWindow.show() }
        updater.closeWindow = { [weak self] in self?.updateWindow.close() }
        updater.isWindowShown = { [weak self] in self?.updateWindow.window?.isVisible ?? false }
        updater.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LG"
        item.button?.toolTip = L10n.App.name
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: L10n.Settings.menuItem,
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        ))
        menu.addItem(NSMenuItem(
            title: L10n.Common.about(L10n.App.name),
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: L10n.Menu.quit(L10n.App.name),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        for entry in menu.items where entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        item.menu = menu
        statusItem = item

        // After launch has finished, so the modal notice doesn't hold it up.
        DispatchQueue.main.async { [settingsStore] in
            LegalNoticeWindow.runAtLaunch(store: settingsStore)
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func showAbout(_ sender: Any?) {
        aboutWindow.show()
    }
}
