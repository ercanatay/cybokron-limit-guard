import Foundation
import LimitGuardCore

/// The app's user-facing text, by area: `L10n.App.name`, `L10n.Menu.quit(_:)`.
///
/// Every entry is a key of `Resources/<language>.lproj/Localizable.strings` with its English text,
/// which `en.lproj` repeats (`LocalizationTests` keep the two in step: add a key to both). Texts
/// with values are functions whose parameters fill the placeholders in order: `%@` takes a
/// `String`, `%ld` an `Int`. Counts pick a `.one` or `.other` key.
enum L10n {
    enum App {
        static var name: String { tr("app.name", "Cybokron Limit Guard") }
    }

    enum Menu {
        static func quit(_ appName: String) -> String { tr("menu.quit", "Quit %@", appName) }
    }
}

// MARK: - Lookup

/// `L10n`'s lookups; the key and English text must be literals (`LocalizationTests` read them).
private func tr(_ key: String, _ english: String) -> String {
    Localization.string(key, english)
}

private func tr(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
    Localization.format(key, english, arguments: arguments)
}
