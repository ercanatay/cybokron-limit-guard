import AppKit
import LimitGuardCore
import OSLog
import UserNotifications

/// Shows the Engine's notes as macOS notifications. The Engine has already applied the
/// `Settings.notify` toggles, so every note that arrives here is shown.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let logger = Logger(subsystem: "com.cybokron.limitguard", category: "notifier")
    private static let explainedKey = "notifications.permissionExplained"
    private static let countdownCategory = "limitguard.countdown"
    private nonisolated static let cancelAction = "limitguard.countdown.cancel"
    private static let countdownIdentifier = "limitguard.countdown"
    private static let unconfirmedCategory = "limitguard.unconfirmed"
    private nonisolated static let sendAgainAction = "limitguard.unconfirmed.sendAgain"
    private nonisolated static let threadIdKey = "threadId"

    /// Called when the owner presses "Cancel" on the countdown notification.
    var onCancelCountdown: (() -> Void)?
    /// Called with the thread id when the owner presses "Send again" on an unconfirmed continue (D24).
    var onSendAgain: ((String) -> Void)?

    /// Notifications need an app bundle (a bare `swift run` binary has none).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    /// Sets up the Cancel action and, the first time, explains and then asks for permission. Call
    /// once the legal notice has been accepted.
    func start() {
        guard let center else { return }
        center.delegate = self
        let cancel = UNNotificationAction(identifier: Self.cancelAction, title: L10n.Notify.cancelAction, options: [])
        let sendAgain = UNNotificationAction(identifier: Self.sendAgainAction, title: L10n.Notify.sendAgainAction, options: [])
        // One call: it replaces every category registered before.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.countdownCategory, actions: [cancel], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.unconfirmedCategory, actions: [sendAgain], intentIdentifiers: []),
        ])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor in self.explainAndRequest() }
        }
    }

    /// Whether macOS lets the app show notifications: nil while not asked yet or without an app bundle.
    func isAllowed() async -> Bool? {
        guard let center else { return nil }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return nil
        }
    }

    private func explainAndRequest() {
        guard let center, !UserDefaults.standard.bool(forKey: Self.explainedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.explainedKey)
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Notify.permissionTitle
        alert.informativeText = L10n.Notify.permissionMessage
        alert.addButton(withTitle: L10n.Notify.permissionContinue)
        alert.runModal()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("notification permission failed: \(String(describing: error), privacy: .public)")
            } else {
                Self.logger.notice("notification permission granted: \(granted, privacy: .public)")
            }
        }
    }

    func post(_ note: EngineNote) {
        guard let center else { return }
        let text = Self.text(for: note)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        var identifier = UUID().uuidString
        if case .continueCountdown = note {
            identifier = Self.countdownIdentifier
            content.categoryIdentifier = Self.countdownCategory
        } else {
            if case let .unconfirmed(threadId) = note {
                content.categoryIdentifier = Self.unconfirmedCategory
                content.userInfo = [Self.threadIdKey: threadId]
            }
            // The countdown is over once the continue is sent, skipped or stopped.
            switch note {
            case .continueSent, .continueSkipped, .unconfirmed, .loopStopped, .runawayStopped:
                center.removeDeliveredNotifications(withIdentifiers: [Self.countdownIdentifier])
            default:
                break
            }
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                Self.logger.error("notification not shown: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func text(for note: EngineNote) -> (title: String, body: String) {
        switch note {
        case .limitReached: return L10n.Notify.limitReached
        case .limitStillReached: return L10n.Notify.limitStillReached
        case .limitIsBack: return L10n.Notify.limitIsBack
        case let .continueCountdown(_, seconds): return L10n.Notify.countdown(seconds)
        case .continueSent: return L10n.Notify.continueSent
        case let .continueSkipped(_, reason): return L10n.Notify.continueSkipped(reason)
        case .unconfirmed: return L10n.Notify.unconfirmed
        case .loopStopped: return L10n.Notify.loopStopped
        case .runawayStopped: return L10n.Notify.runawayStopped
        case let .resetUsed(outcome): return L10n.Notify.resetUsed(outcome)
        case .resetResultUnknown: return L10n.Notify.resetUnknown
        case let .resetExpiring(_, date):
            return L10n.Notify.resetExpiring(date.formatted(date: .abbreviated, time: .shortened))
        case let .readOnly(reason): return L10n.Notify.readOnly(reason)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        switch response.actionIdentifier {
        case Self.cancelAction:
            await MainActor.run { onCancelCountdown?() }
        case Self.sendAgainAction:
            // `userInfo` isn't Sendable: take the id out before going to the main actor.
            guard let threadId = response.notification.request.content.userInfo[Self.threadIdKey] as? String else { return }
            await MainActor.run { onSendAgain?(threadId) }
        default:
            break
        }
    }
}
