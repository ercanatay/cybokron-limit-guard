import AppKit

extension NSWindowController {
    /// Shows the window in front of other apps' windows. The app is an accessory (no Dock icon),
    /// so activation alone doesn't reliably raise a window opened from the status-item menu.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
