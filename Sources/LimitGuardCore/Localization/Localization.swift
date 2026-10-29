import Foundation

/// User-facing text, looked up in the app's string tables (`Resources/<language>.lproj/
/// Localizable.strings`, copied into the app bundle).
///
/// Each lookup names a key and its English text. `en.lproj` holds that same English text for the
/// key (the unit tests check they agree), and it's also what shows when there's no table to read —
/// in the unit tests or a bare `swift run` — or a translation lacks the key.
///
/// Format strings take `String(format:)` placeholders: `%@` for text, `%ld` for whole numbers, and
/// numbered ones (`%1$@`, `%2$ld`) when there are several, so translations can reorder them.
public enum Localization {
    /// The bundle whose tables the lookups read: the app's, or for one task another one, such as a
    /// single language's table (`table(for:)`) or the repository's tables in the tests.
    @TaskLocal public static var bundle: Bundle = .main

    /// The text for `key` in the user's language, `english` when there's none.
    public static func string(_ key: String, _ english: String) -> String {
        string(key, english, in: bundle)
    }

    /// The table of `locale`'s language in the current `bundle`, or that bundle itself when it has none.
    public static func table(for locale: Locale) -> Bundle {
        let base = bundle
        guard let code = locale.language.languageCode?.identifier,
              let path = base.path(forResource: code, ofType: "lproj"),
              let table = Bundle(path: path)
        else { return base }
        return table
    }

    /// The text for `key` in `bundle`'s table, the key itself when it has none.
    public static func string(_ key: String, bundle: Bundle = .main) -> String {
        string(key, key, in: bundle)
    }

    /// `string(_:_:)` with `arguments` put into its placeholders.
    public static func format(_ key: String, _ english: String, _ arguments: any CVarArg...) -> String {
        format(key, english, arguments: arguments)
    }

    /// `format(_:_:_:)` with the arguments as an array, for helpers that pass theirs on.
    public static func format(_ key: String, _ english: String, arguments: [any CVarArg]) -> String {
        String(format: string(key, english), locale: .current, arguments: arguments)
    }

    /// `string(_:bundle:)` with `arguments` put into its placeholders; the key is the fallback text.
    public static func format(_ key: String, arguments: [any CVarArg]) -> String {
        String(format: string(key), locale: .current, arguments: arguments)
    }

    /// The lookup itself, in any bundle (the tests use one of their own).
    static func string(_ key: String, _ english: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: english, table: nil)
    }
}
