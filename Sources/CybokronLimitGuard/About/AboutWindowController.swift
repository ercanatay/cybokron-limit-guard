import AppKit
import SwiftUI
import LimitGuardCore

/// The About window: the app icon, version and license, and where the idea came from.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let hostingController = NSHostingController(rootView: AboutView())
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.Common.about(AppInfo.name)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: AboutView.width, height: 720))
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings the app to the front.
    func show() {
        if let window, !window.isVisible {
            window.layoutIfNeeded()
            window.center()
        }
        bringToFront()
    }
}

/// The About window's content: `AboutContentView` (Settings → Support shows it too), scrolling
/// on the panel's background.
private struct AboutView: View {
    static let width: CGFloat = 460

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            AboutContentView()
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
        }
        .frame(width: Self.width, height: 720)
        .background(PanelPalette.forScheme(scheme).solidBackground)
    }
}
