import Foundation
import LimitGuardCore

// MARK: - Settings window

extension L10n.Settings {
    static var windowTitle: String { tr("settings.window.title", "Settings") }
    static var menuItem: String { tr("settings.menuItem", "Settings…") }
    static var generalTab: String { tr("settings.tab.general", "General") }
    static var continueTab: String { tr("settings.tab.continue", "Continue") }
    static var resetsTab: String { tr("settings.tab.resets", "Resets") }
    static var notificationsTab: String { tr("settings.tab.notifications", "Notifications") }

    static var readOnlyNewer: String {
        tr(
            "settings.readOnly.newer",
            "The settings file was written by a newer version of the app. Settings are shown read-only and nothing is saved, so that file stays untouched."
        )
    }
    static var readOnlyUnreadable: String {
        tr(
            "settings.readOnly.unreadable",
            "The settings file can't be read. Settings are shown read-only and nothing is saved, so that file stays untouched."
        )
    }
    static var saveFailed: String { tr("settings.saveFailed", "The settings couldn't be saved.") }

    enum General {
        static var launchAtLogin: String { tr("settings.general.launchAtLogin", "Launch at login") }
        static var launchNeedsApproval: String {
            tr("settings.general.launchNeedsApproval", "Allow the app in System Settings → General → Login Items.")
        }
        static var openLoginItems: String { tr("settings.general.openLoginItems", "Open Login Items…") }
        static func launchFailed(_ reason: String) -> String {
            tr("settings.general.launchFailed", "Couldn't change the login item: %@", reason)
        }
        static var showPercent: String { tr("settings.general.showPercent", "Show percentage in menu bar") }
        static var keepAwake: String { tr("settings.general.keepAwake", "Keep Mac awake while waiting") }
        static var keepAwakeHelp: String {
            tr(
                "settings.general.keepAwakeHelp",
                "Only between a usage-limit stop and the continue. The display may still sleep."
            )
        }
        static var guardNewTabs: String { tr("settings.general.guardNewTabs", "Guard new Codex tabs automatically") }
        static var guardNewTabsHelp: String {
            tr("settings.general.guardNewTabsHelp", "Off: you choose which tabs to guard from the menu.")
        }

        static var codexHeader: String { tr("settings.general.codex.header", "Codex") }
        static var codexPath: String { tr("settings.general.codex.path", "Codex path") }
        static var codexNotFound: String { tr("settings.general.codex.notFound", "Codex not found") }
        static var codexChoose: String { tr("settings.general.codex.choose", "Choose…") }
        static var codexReveal: String { tr("settings.general.codex.reveal", "Reveal") }
        static var codexReset: String { tr("settings.general.codex.reset", "Reset") }
        static var codexOverrideInvalid: String {
            tr("settings.general.codex.overrideInvalid", "The chosen file isn't an executable; the automatic lookup is used instead.")
        }
        static var codexPanelMessage: String { tr("settings.general.codex.panelMessage", "Choose the codex executable") }

        static var languageHeader: String { tr("settings.general.language.header", "Language") }
        static var language: String { tr("settings.general.language", "Language") }
        static var languageSystem: String { tr("settings.general.language.system", "System") }
        static var languageEnglish: String { tr("settings.general.language.english", "English") }
        static var languageTurkish: String { tr("settings.general.language.turkish", "Türkçe") }
        static var restartTitle: String { tr("settings.general.restart.title", "Restart to change the language?") }
        static func restartMessage(_ appName: String) -> String {
            tr("settings.general.restart.message", "%@ uses the new language after it restarts.", appName)
        }
        static var restartNow: String { tr("settings.general.restart.now", "Restart Now") }
        static var restartLater: String { tr("settings.general.restart.later", "Later") }

        static var aboutHeader: String { tr("settings.general.about.header", "Notice and checks") }
        static var showNotice: String { tr("settings.general.showNotice", "Show legal notice") }
        static var runDiagnostics: String { tr("settings.general.runDiagnostics", "Run Diagnostics") }
    }

    enum Continue {
        static var autoContinue: String { tr("settings.continue.auto", "Continue automatically when the limit is back") }
        static func countdown(_ seconds: Int) -> String {
            tr("settings.continue.countdown", "Countdown before typing: %ld s", seconds)
        }
        static func maxTries(_ count: Int) -> String {
            tr("settings.continue.maxTries", "Maximum continues in a row: %ld", count)
        }
        static func minGap(_ minutes: Int) -> String {
            tr("settings.continue.minGap", "Minimum gap between continues: %ld min", minutes)
        }
        static var textsHeader: String { tr("settings.continue.texts.header", "Text to type, by language") }
        static var textsFooter: String {
            tr(
                "settings.continue.texts.footer",
                "The app recognises the language of the conversation and types the matching text. Other languages get the fallback text."
            )
        }
        static var languageCode: String { tr("settings.continue.texts.code", "Language code") }
        static var text: String { tr("settings.continue.texts.text", "Text") }
        static var add: String { tr("settings.continue.texts.add", "Add") }
        static func remove(_ code: String) -> String { tr("settings.continue.texts.remove", "Remove the text for %@", code) }
        static var fallback: String { tr("settings.continue.fallback", "Fallback text") }
    }

    enum Resets {
        static var autoUse: String {
            tr("settings.resets.autoUse", "Use a reset credit when the weekly limit is almost used up")
        }
        static var autoUseCaption: String {
            tr(
                "settings.resets.autoUseCaption",
                "At most one automatic reset per account every 7 days. Only while Codex is in use."
            )
        }
        static func threshold(_ percent: Int) -> String {
            let formatted = percent.formatted(.percent.scale(1))
            return tr("settings.resets.threshold", "When the weekly limit is %@ used", formatted)
        }
        static var expiryReminders: String {
            tr("settings.resets.expiryReminders", "Remind me before a reset credit expires")
        }
    }

    enum Notifications {
        static var header: String { tr("settings.notifications.header", "Notify me when") }
        static var limitReached: String { tr("settings.notifications.limitReached", "A usage limit is reached") }
        static var limitIsBack: String { tr("settings.notifications.limitIsBack", "The limit is back") }
        static var continueSent: String { tr("settings.notifications.continueSent", "A continue was sent") }
        static var continueSkipped: String { tr("settings.notifications.continueSkipped", "A continue was skipped or stopped") }
        static var resetUsed: String { tr("settings.notifications.resetUsed", "A reset credit was used") }
        static var resetExpiring: String { tr("settings.notifications.resetExpiring", "A reset credit is about to expire") }
        static var readOnly: String { tr("settings.notifications.readOnly", "The app switches to read-only mode") }
    }
}

private func tr(_ key: String, _ english: String) -> String {
    Localization.string(key, english)
}

private func tr(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
    Localization.format(key, english, arguments: arguments)
}
