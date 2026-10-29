import AppKit
import Combine
import LimitGuardCore

/// The menu-bar item with its popover, the windows, the Engine, and the single-copy handoff.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var secondCopyHandoff: SecondCopyHandoff?
    private var handedOffURLs = false
    /// `cybokronlimitguard://` URLs that arrived before the status item existed.
    private var pendingURLs: [URL] = []
    private let updater = AutoUpdater()
    private lazy var updateWindow = UpdateWindowController(updater: updater)
    private lazy var aboutWindow = AboutWindowController()
    private lazy var diagnosticsWindow = DiagnosticsWindowController()
    private lazy var activityWindow = ActivityWindowController(
        load: { (try? ActivityLog(url: AppPaths.activityURL).entries()) ?? [] },
        clear: { try? ActivityLog(url: AppPaths.activityURL).clear() }
    )
    private lazy var chartWindow = UsageChartWindowController(load: { await StoredChartFeed.load() })
    private let settingsStore = JSONStore<Settings>(url: AppPaths.settingsURL, schemaVersion: 1)
    private lazy var settingsWindow = SettingsWindowController(
        store: settingsStore,
        updater: updater,
        runDiagnostics: { [weak self] in self?.diagnosticsWindow.show() }
    )

    private lazy var engineHost = EngineHost(settingsStore: settingsStore)
    private var subscriptions = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Decided before any URL arrives, so a second copy never handles one itself.
        secondCopyHandoff = SecondCopyHandoff.toOlderRunningCopy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let handoff = secondCopyHandoff {
            if !handedOffURLs { handoff.handOff([]) }
            return
        }
        updater.showWindow = { [weak self] in self?.updateWindow.show() }
        updater.closeWindow = { [weak self] in self?.updateWindow.close() }
        updater.isWindowShown = { [weak self] in self?.updateWindow.window?.isVisible ?? false }
        updater.start()

        let store = settingsStore
        let item = StatusItemController(
            actions: PopoverActions(
                showSettings: { [weak self] in self?.settingsWindow.show() },
                showActivity: { [weak self] in self?.activityWindow.show() },
                showChart: { [weak self] in self?.chartWindow.show() },
                showAbout: { [weak self] in self?.aboutWindow.show() },
                resetSettings: { SettingsReset.run(store: store) }
            ),
            notifier: engineHost.notifier,
            loadSettings: { (try? store.load()?.clamped()) ?? Settings() },
            settingsStatus: { SettingsRecovery.status(of: store) }
        )
        statusItem = item
        // The "Show percentage in menu bar" setting takes effect at once.
        NotificationCenter.default.publisher(for: .limitGuardSettingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak item] _ in item?.settingsChanged() }
            .store(in: &subscriptions)

        // After launch has finished, so the modal notice doesn't hold it up.
        engineHost.onChange = { [weak self] in self?.updateEngineStatus() }
        DispatchQueue.main.async { [weak self, settingsStore] in
            guard LegalNoticeWindow.runAtLaunch(store: settingsStore) else { return }
            Task { await self?.engineHost.start() }
        }
        let early = pendingURLs
        pendingURLs = []
        early.forEach(handle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A second copy started nothing; the copy that runs owns the files.
        guard secondCopyHandoff == nil else { return }
        engineHost.stop()
    }

    /// Opening the app again (Finder, `open -a`, a second copy handing over) shows the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.show()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let secondCopyHandoff {
            handedOffURLs = true
            secondCopyHandoff.handOff(urls)
            return
        }
        guard statusItem != nil else {
            pendingURLs += urls
            return
        }
        urls.forEach(handle)
    }

    /// `cybokronlimitguard://settings` opens Settings; any other path of the scheme shows the popover.
    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "cybokronlimitguard" else { return }
        if url.host?.lowercased() == "settings" {
            settingsWindow.show()
        } else {
            statusItem?.show()
        }
    }

    private func updateEngineStatus() {
        statusItem?.update(engine: engineHost.engine, codexFound: engineHost.codexFound)
    }
}
