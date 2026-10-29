import AppKit
import LimitGuardCore
import SwiftUI

/// The Settings window (⌘,): General, Continue, Resets, Notifications, Updates, Changelog and
/// Support, each in its own pane picked from a sidebar.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "SettingsWindow"
    /// The panes' height on a screen with room for it; shorter screens get shorter panes.
    private static let idealPaneHeight: CGFloat = 560
    /// The panes don't shrink below this, however short the screen.
    private static let minimumPaneHeight: CGFloat = 320
    /// Room kept between the window and the edges of the screen's usable area.
    private static let screenMargin: CGFloat = 40
    private let hostingController: NSHostingController<SettingsView>
    private let model: SettingsModel

    init(store: JSONStore<LimitGuardCore.Settings>, updater: AutoUpdater, runDiagnostics: @escaping () -> Void) {
        let model = SettingsModel(store: store)
        // Reads the saved release list now, so the Changelog pane shows it at once.
        let changelog = ChangelogService(
            fetcher: GitHubChangelogFeed(appVersion: AppInfo.version),
            currentVersion: SemanticVersion(AppInfo.version)
        )
        let hostingController = NSHostingController(
            rootView: SettingsView(
                model: model,
                updater: updater,
                changelog: changelog,
                runDiagnostics: runDiagnostics,
                paneHeight: Self.idealPaneHeight
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.Settings.windowTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.hostingController = hostingController
        self.model = model
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings the app to the front. The file is read again first: the legal
    /// notice (or a newer app version) may have written it since the window was last shown.
    func show() {
        model.reload()
        fitToScreen()
        bringToFront()
    }

    /// Makes the panes as tall as the screen the window is on has room for, and keeps the whole
    /// window inside that screen's usable area.
    private func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let titleBarHeight = window.frameRect(forContentRect: .zero).height
        let available = visible.height - titleBarHeight - 2 * Self.screenMargin
        hostingController.rootView.paneHeight = min(Self.idealPaneHeight, max(Self.minimumPaneHeight, available))
        hostingController.view.layoutSubtreeIfNeeded()

        let previous = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: hostingController.preferredContentSize))
        frame.origin.x = max(visible.minX, min(previous.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(previous.maxY - frame.height, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }
}

/// The Settings window's panes, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case continueText
    case resets
    case notifications
    case updates
    case changelog
    case support

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L10n.Settings.generalTab
        case .continueText: L10n.Settings.continueTab
        case .resets: L10n.Settings.resetsTab
        case .notifications: L10n.Settings.notificationsTab
        case .updates: L10n.Settings.updatesTab
        case .changelog: L10n.Changelog.tab
        case .support: L10n.Settings.supportTab
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .continueText: "arrow.uturn.forward.circle"
        case .resets: "arrow.counterclockwise.circle"
        case .notifications: "bell"
        case .updates: "arrow.triangle.2.circlepath"
        case .changelog: "newspaper"
        case .support: "heart"
        }
    }
}

/// The panes listed in a sidebar, as in System Settings, with the selected one beside it.
private struct SettingsView: View {
    private static let sidebarWidth: CGFloat = 180
    private static let selectedPaneKey = "SettingsSelectedPane"

    @ObservedObject var model: SettingsModel
    let updater: AutoUpdater
    let changelog: ChangelogService
    let runDiagnostics: () -> Void
    /// Set by `SettingsWindowController` to fit the screen.
    var paneHeight: CGFloat

    /// The pane shown, kept across launches as the window's frame is.
    @AppStorage(SettingsView.selectedPaneKey) private var selectedPane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            // A required selection: one pane stays selected, whatever is clicked.
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)
            Divider()
            paneView
        }
        // Each pane's grouped Form fills this height and scrolls; the panes must not fix their own.
        .frame(height: paneHeight)
    }

    @ViewBuilder
    private var paneView: some View {
        switch selectedPane {
        case .general:
            GeneralSettingsView(model: model, runDiagnostics: runDiagnostics)
        case .continueText:
            ContinueSettingsView(model: model)
        case .resets:
            ResetsSettingsView(model: model)
        case .notifications:
            NotificationsSettingsView(model: model)
        case .updates:
            UpdatesSettingsView(updater: updater)
        case .changelog:
            ChangelogSettingsView(changelog: changelog)
        case .support:
            SupportSettingsView()
        }
    }
}
