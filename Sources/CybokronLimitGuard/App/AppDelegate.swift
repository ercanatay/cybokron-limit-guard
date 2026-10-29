import AppKit
import Combine
import LimitGuardCore

/// Placeholder shell: a status item (gauge symbol) with the engine status line, a pause toggle,
/// Settings…, About and Quit. The popover comes later.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusLineItem = NSMenuItem(title: L10n.EngineStatus.starting, action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: L10n.EngineStatus.pause, action: nil, keyEquivalent: "")
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard handOffToRunningInstance() else { return }
        updater.showWindow = { [weak self] in self?.updateWindow.show() }
        updater.closeWindow = { [weak self] in self?.updateWindow.close() }
        updater.isWindowShown = { [weak self] in self?.updateWindow.window?.isVisible ?? false }
        updater.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let symbol = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: L10n.App.name)
            ?? NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: L10n.App.name)
        symbol?.isTemplate = true
        item.button?.image = symbol
        item.button?.toolTip = L10n.App.name
        let menu = NSMenu()
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        pauseItem.action = #selector(togglePause(_:))
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: L10n.Settings.menuItem,
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        ))
        // Temporary: the engine will feed these windows with live data.
        menu.addItem(NSMenuItem(title: L10n.Activity.menuItem, action: #selector(showActivity(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.Chart.menuItem, action: #selector(showChart(_:)), keyEquivalent: ""))
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
        engineHost.onChange = { [weak self] in self?.updateEngineStatus() }
        DispatchQueue.main.async { [weak self, settingsStore] in
            guard LegalNoticeWindow.runAtLaunch(store: settingsStore) else { return }
            Task { await self?.engineHost.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engineHost.stop()
    }

    /// One copy per user session: a second launch activates the first and quits, so there is only one
    /// reset ledger and one executor. Returns false when this copy is going away.
    private func handOffToRunningInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        func olderCopies() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
                $0.processIdentifier != me.processIdentifier
                    && ($0.launchDate ?? .distantFuture) < (me.launchDate ?? .distantPast)
            }
        }
        // A copy that is just quitting (restart after a language change or an update) gets a moment to go.
        for _ in 0..<30 where !olderCopies().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        guard let other = olderCopies().first else { return true }
        other.activate()
        NSApp.terminate(nil)
        return false
    }

    private func updateEngineStatus() {
        guard let engine = engineHost.engine else { return }
        statusLineItem.title = Self.statusLine(engine: engine, codexFound: engineHost.codexFound)
        pauseItem.state = engine.isPaused ? .on : .off
    }

    /// "5h 100% · W 16%", plus "Paused" / "Read-only" when they apply.
    static func statusLine(engine: Engine, codexFound: Bool) -> String {
        var parts: [String] = []
        if let snapshot = engine.snapshot {
            let five = snapshot.fiveHour.map { Int($0.usedPercent.rounded()) }
            let week = snapshot.weekly.map { Int($0.usedPercent.rounded()) }
            switch (five, week) {
            case let (five?, week?): parts.append(L10n.EngineStatus.limits(fiveHour: five, weekly: week))
            case let (five?, nil): parts.append(L10n.EngineStatus.fiveHourOnly(five))
            case let (nil, week?): parts.append(L10n.EngineStatus.weeklyOnly(week))
            case (nil, nil): parts.append(L10n.EngineStatus.unavailable)
            }
        } else if !codexFound {
            parts.append(L10n.EngineStatus.codexMissing)
        } else if engine.readError != nil {
            parts.append(L10n.EngineStatus.unavailable)
        } else {
            parts.append(L10n.EngineStatus.reading)
        }
        if case .readOnly = engine.health { parts.append(L10n.EngineStatus.readOnly) }
        if engine.isPaused { parts.append(L10n.EngineStatus.paused) }
        return parts.joined(separator: " · ")
    }

    @objc private func togglePause(_ sender: Any?) {
        guard let engine = engineHost.engine else { return }
        engine.pause(!engine.isPaused)
        updateEngineStatus()
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func showActivity(_ sender: Any?) {
        activityWindow.show()
    }

    @objc private func showChart(_ sender: Any?) {
        chartWindow.show()
    }

    @objc private func showAbout(_ sender: Any?) {
        aboutWindow.show()
    }
}
