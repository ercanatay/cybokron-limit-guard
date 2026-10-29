import AppKit

/// Placeholder shell: a status item showing "LG" and a Quit item, so the app launches.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "LG"
        item.button?.toolTip = L10n.App.name
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: L10n.Menu.quit(L10n.App.name),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        item.menu = menu
        statusItem = item
    }
}
