import AppKit
import LimitGuardCore
import SwiftUI

/// The settings the window edits: loaded from `settings.json`, written back on every change.
///
/// A file from a newer app version (or one that can't be read) is never overwritten: the model then
/// stays `isReadOnly`, the panes disable their controls and say why.
@MainActor
final class SettingsModel: ObservableObject {
    enum ReadOnlyReason {
        case newerSchema
        case unreadable
    }

    @Published private(set) var settings = LimitGuardCore.Settings()
    @Published private(set) var readOnlyReason: ReadOnlyReason?
    @Published private(set) var saveFailed = false
    @Published private(set) var loginItemState = LoginItem.state
    @Published private(set) var loginItemFailed = false

    private let store: JSONStore<LimitGuardCore.Settings>

    init(store: JSONStore<LimitGuardCore.Settings>) {
        self.store = store
        reload()
    }

    var isReadOnly: Bool { readOnlyReason != nil }

    /// Re-reads the file (it may have changed since the window was last shown).
    func reload() {
        saveFailed = false
        loginItemFailed = false
        loginItemState = LoginItem.state
        do {
            settings = try store.load()?.clamped() ?? LimitGuardCore.Settings()
            readOnlyReason = nil
        } catch StoreError.newerSchema {
            settings = LimitGuardCore.Settings()
            readOnlyReason = .newerSchema
        } catch {
            settings = LimitGuardCore.Settings()
            readOnlyReason = .unreadable
        }
    }

    func mutate(_ change: (inout LimitGuardCore.Settings) -> Void) {
        guard !isReadOnly else { return }
        var updated = settings
        change(&updated)
        updated = updated.clamped()
        guard updated != settings else { return }
        settings = updated
        do {
            try store.save(updated)
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<LimitGuardCore.Settings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.mutate { $0[keyPath: keyPath] = value } }
        )
    }

    func notifyBinding<Value>(_ keyPath: WritableKeyPath<NotificationToggles, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings.notify[keyPath: keyPath] },
            set: { value in self.mutate { $0.notify[keyPath: keyPath] = value } }
        )
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { loginItemState != .disabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isReadOnly else { return }
        loginItemFailed = false
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            loginItemFailed = true
        }
        loginItemState = LoginItem.state
        mutate { $0.launchAtLogin = loginItemState != .disabled }
    }

    // MARK: Language

    /// Writes the choice to the app's own `AppleLanguages` default and asks for a restart.
    func setLanguage(_ language: AppLanguage) {
        guard !isReadOnly, language != settings.language else { return }
        mutate { $0.language = language }
        if let languages = language.appleLanguages {
            UserDefaults.standard.set(languages, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        offerRestart()
    }

    private func offerRestart() {
        let alert = NSAlert()
        alert.messageText = L10n.Settings.General.restartTitle
        alert.informativeText = L10n.Settings.General.restartMessage(L10n.App.name)
        alert.addButton(withTitle: L10n.Settings.General.restartNow)
        alert.addButton(withTitle: L10n.Settings.General.restartLater)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
