import AppKit
import LimitGuardCore
import SwiftUI

/// What the popover's footer and rows open or do outside the popover itself.
struct PopoverActions {
    var showSettings: () -> Void
    var showActivity: () -> Void
    var showChart: () -> Void
    var showAbout: () -> Void
}

/// The popover's state that outlives the popover: the Engine once it runs, and the manual actions in
/// flight with their results. A transient popover closes for the confirmation alert, so nothing of
/// this may live in a view's `@State`.
@MainActor
final class PopoverModel: ObservableObject {
    @Published private(set) var engine: Engine?
    @Published private(set) var codexFound = true
    /// nil: not asked yet, or no app bundle.
    @Published private(set) var notificationsAllowed: Bool?
    /// The credit whose "Use Reset" runs; every Use Reset button waits for it.
    @Published private(set) var spendingCreditId: String?
    /// The last result per credit, shown inline under its row.
    @Published private(set) var creditResults: [String: SpendResult] = [:]
    @Published private(set) var continuing: Set<String> = []

    let actions: PopoverActions
    /// Shows the popover again after an alert closed it.
    var reopen: () -> Void = {}
    private let notifier: Notifier

    init(actions: PopoverActions, notifier: Notifier) {
        self.actions = actions
        self.notifier = notifier
    }

    func attach(engine: Engine?, codexFound: Bool) {
        if self.engine !== engine { self.engine = engine }
        if self.codexFound != codexFound { self.codexFound = codexFound }
    }

    func refreshPermissions() {
        Task {
            let allowed = await notifier.isAllowed()
            if allowed != notificationsAllowed { notificationsAllowed = allowed }
        }
    }

    /// Confirmation alert (D11), then the Engine's manual spend for exactly this credit.
    func useReset(_ row: CreditRow) {
        guard let engine, spendingCreditId == nil, row.canUse else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Popover.Resets.confirmTitle
        alert.informativeText = [row.title ?? L10n.Popover.Resets.untitled, L10n.Popover.Resets.confirmMessage]
            .joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.Popover.Resets.use)
        alert.addButton(withTitle: L10n.Common.cancel)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        reopen()
        guard confirmed else { return }
        spendingCreditId = row.id
        creditResults[row.id] = nil
        let creditId = row.id
        Task {
            let result = await engine.useReset(creditId: creditId)
            creditResults[creditId] = result
            spendingCreditId = nil
        }
    }

    func continueNow(threadId: String) {
        guard let engine, !continuing.contains(threadId) else { return }
        continuing.insert(threadId)
        Task {
            await engine.continueNow(threadId: threadId)
            continuing.remove(threadId)
        }
    }
}

/// The menu-bar item (spec §4.1) and its popover (§4.2).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    let model: PopoverModel
    private let loadSettings: () -> LimitGuardCore.Settings

    init(actions: PopoverActions, notifier: Notifier, loadSettings: @escaping () -> LimitGuardCore.Settings) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model = PopoverModel(actions: actions, notifier: notifier)
        self.loadSettings = loadSettings
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(model: model, closePopover: { [weak self] in self?.close() }))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        model.reopen = { [weak self] in self?.show() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = L10n.App.name
            button.setAccessibilityLabel(L10n.App.name)
        }
        refresh()
    }

    /// Follows the Engine and the settings: icon, pause glyph, text and its colour.
    func update(engine: Engine?, codexFound: Bool) {
        model.attach(engine: engine, codexFound: codexFound)
        refresh()
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let engine = model.engine
        let paused = engine?.isPaused ?? false
        let result = MenuBarText.make(snapshot: engine?.snapshot, showPercent: loadSettings().showPercentInMenuBar)
        button.image = Self.icon(paused: paused)
        if let text = result.text {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ]
            switch result.level {
            case .normal: break
            case .warning: attributes[.foregroundColor] = NSColor.systemOrange
            case .critical: attributes[.foregroundColor] = NSColor.systemRed
            }
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: attributes)
            button.imagePosition = .imageLeading
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }
        var label = L10n.App.name
        if let text = result.text { label += ", " + text }
        if paused { label += ", " + L10n.EngineStatus.paused }
        button.setAccessibilityLabel(label)
    }

    /// The gauge as a template image; paused, with a small pause glyph beside it.
    private static func icon(paused: Bool) -> NSImage? {
        guard let gauge = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: L10n.App.name)
            ?? NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: L10n.App.name)
        else { return nil }
        guard paused,
              let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: L10n.EngineStatus.paused)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .heavy))
        else {
            gauge.isTemplate = true
            return gauge
        }
        let size = NSSize(width: gauge.size.width + pause.size.width + 1, height: gauge.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            gauge.draw(in: NSRect(origin: .zero, size: gauge.size))
            pause.draw(in: NSRect(x: size.width - pause.size.width, y: 0, width: pause.size.width, height: pause.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func togglePopover(_ sender: Any?) {
        popover.isShown ? close() : show()
    }

    func show() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.refreshPermissions()
        // An accessory app must be active for the popover to take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }
}
