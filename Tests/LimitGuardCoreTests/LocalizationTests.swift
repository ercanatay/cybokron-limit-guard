import Foundation
import Testing
@testable import LimitGuardCore

/// The string tables (`Resources/<language>.lproj/Localizable.strings`) against the sources: every
/// key the code looks up has its English text in `en.lproj`, word for word, and nothing more;
/// every translation has the same keys with the same placeholders. Reads the files from the
/// repository, so it needs no bundle resources.
@Suite("Localization")
struct LocalizationTests {
    /// The repository: three levels up from this file (`Tests/LimitGuardCoreTests/…`).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let resources = root.appending(path: "Resources", directoryHint: .isDirectory)

    /// One lookup in the sources: `tr("key", "English", arguments…)` in `L10n`, or
    /// `Localization.string` / `Localization.format` in LimitGuardCore.
    struct Lookup {
        let key: String
        let english: String
        let argumentCount: Int
        let file: String
    }

    // MARK: - Reading

    static func table(_ language: String) throws -> [String: String] {
        let url = resources.appending(components: "\(language).lproj", "Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String], "\(language).lproj/Localizable.strings isn't a strings table")
    }

    /// Key prefixes of texts added after the last translation pass, still English only:
    /// translations may lack these keys (the lookup then shows the English text) but not have others,
    /// and the keys they do have keep the English placeholders. Add a prefix here when new
    /// untranslated keys are added, and remove it once every language has its keys.
    static let awaitingTranslation: [String] = []

    static func isAwaitingTranslation(_ key: String) -> Bool {
        awaitingTranslation.contains { key.hasPrefix($0) }
    }

    static var languages: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) }.sorted()
    }

    static func lookups() throws -> [Lookup] {
        let call = try NSRegularExpression(pattern: #"""
            (?:\btr|Localization\.string|Localization\.format)\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"((?:\s*,\s*[A-Za-z_][A-Za-z0-9_.]*)*)\s*\)
            """#)
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var lookups: [Lookup] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "Localization.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            let matches = call.matches(in: text, range: range)
            // Every lookup must have literal arguments the expression can read.
            let starts = try NSRegularExpression(pattern: #"(?:\btr|Localization\.string|Localization\.format)\(\s*""#)
            #expect(starts.numberOfMatches(in: text, range: range) == matches.count, "unreadable lookup in \(url.lastPathComponent)")
            for match in matches {
                let part = { (index: Int) in String(text[Range(match.range(at: index), in: text)!]) }
                let arguments = part(3).split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                lookups.append(Lookup(
                    key: part(1),
                    english: try unescapeSwiftLiteral(part(2)),
                    argumentCount: arguments.count,
                    file: url.lastPathComponent
                ))
            }
        }
        return lookups
    }

    /// The text of a Swift string literal's contents (the escapes the sources use).
    static func unescapeSwiftLiteral(_ literal: String) throws -> String {
        var result = ""
        var characters = literal.makeIterator()
        while let character = characters.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch characters.next() {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "\\": result.append("\\")
            case let other:
                Issue.record("unsupported escape \\\(other.map(String.init) ?? "") (no interpolation) in “\(literal)”")
            }
        }
        return result
    }

    /// A format string's placeholders as (position, conversion), e.g. `[(1, "@"), (2, "ld")]`.
    static func placeholders(_ format: String) -> [Placeholder] {
        let expression = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?((?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSpaA%])"#)
        var result: Set<Placeholder> = []
        var next = 1
        for match in expression.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            let conversion = String(format[Range(match.range(at: 2), in: format)!])
            guard conversion != "%" else { continue }
            let position: Int
            if let range = Range(match.range(at: 1), in: format) {
                position = Int(format[range])!
            } else {
                position = next
                next += 1
            }
            result.insert(Placeholder(position: position, conversion: conversion))
        }
        return result.sorted { ($0.position, $0.conversion) < ($1.position, $1.conversion) }
    }

    /// Whether `format` numbers some placeholders (`%1$@`) and not others (`%@`): which value a
    /// plain one then takes isn't defined, and `placeholders` would count it as matching anyway.
    static func mixesNumberedAndPlainPlaceholders(_ format: String) -> Bool {
        let expression = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?((?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGcCsSpaA%])"#)
        var kinds: Set<Bool> = []
        for match in expression.matches(in: format, range: NSRange(format.startIndex..., in: format)) {
            guard String(format[Range(match.range(at: 2), in: format)!]) != "%" else { continue }
            kinds.insert(match.range(at: 1).location != NSNotFound)
        }
        return kinds.count > 1
    }

    struct Placeholder: Hashable, CustomStringConvertible {
        let position: Int
        let conversion: String
        var description: String { "%\(position)$\(conversion)" }
    }

    // MARK: - English table

    @Test func englishTableIsReadableAndComplete() throws {
        let english = try Self.table("en")
        #expect(!english.isEmpty)
        let keyPattern = try NSRegularExpression(pattern: #"^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+$"#)
        for (key, value) in english {
            #expect(keyPattern.numberOfMatches(in: key, range: NSRange(key.startIndex..., in: key)) == 1, "odd key \(key)")
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty text for \(key)")
        }
    }

    @Test func sourcesAndEnglishTableAgree() throws {
        let english = try Self.table("en")
        let lookups = try Self.lookups()
        #expect(!lookups.isEmpty)
        var seen: [String: String] = [:]
        for lookup in lookups {
            if let earlier = seen[lookup.key] {
                #expect(earlier == lookup.english, "\(lookup.key) has two English texts (\(lookup.file))")
            }
            seen[lookup.key] = lookup.english
            #expect(english[lookup.key] == lookup.english, """
                en.lproj needs, for \(lookup.file):
                "\(lookup.key)" = "\(lookup.english.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))";
                """)
        }
        let unused = Set(english.keys).subtracting(seen.keys)
        #expect(unused.isEmpty, "keys no source looks up: \(unused.sorted())")
    }

    @Test func formatStringsMatchTheirArguments() throws {
        for lookup in try Self.lookups() {
            let placeholders = Self.placeholders(lookup.english)
            if lookup.argumentCount == 0 {
                // Shown as they are, so a % would show too: plain texts have none.
                #expect(!lookup.english.contains("%"), "\(lookup.key) has a % but no arguments")
            } else {
                #expect(Set(placeholders.map(\.position)) == Set(1...lookup.argumentCount),
                        "\(lookup.key): \(lookup.argumentCount) arguments for \(placeholders)")
                #expect(placeholders.allSatisfy { ["@", "ld"].contains($0.conversion) },
                        "\(lookup.key): use %@ for text and %ld for numbers, not \(placeholders)")
            }
        }
    }

    /// Spot checks of the table, key to text.
    @Test(arguments: [
        ("app.name", "Cybokron Limit Guard"),
        ("menu.quit", "Quit %@"),
    ])
    func englishText(key: String, text: String) throws {
        #expect(try Self.table("en")[key] == text)
    }

    /// A count's texts come in pairs: `.one` for 1 and `.other`, which shows the number, for the
    /// rest — in every language that has them.
    @Test func countsHaveASingularAndAPluralText() throws {
        let english = try Self.table("en")
        let ones = Set(english.keys.filter { $0.hasSuffix(".one") }.map { String($0.dropLast(".one".count)) })
        let others = Set(english.keys.filter { $0.hasSuffix(".other") }.map { String($0.dropLast(".other".count)) })
        #expect(ones == others, "unpaired counts: \(ones.symmetricDifference(others).sorted())")
        for language in Self.languages {
            let table = try Self.table(language)
            for count in others {
                guard let plural = table["\(count).other"] else { continue }
                #expect(Self.placeholders(plural).contains { $0.conversion == "ld" }, "\(language) \(count).other doesn't show the number: \(plural)")
                #expect(table["\(count).one"] != nil, "\(language) has \(count).other without \(count).one")
            }
        }
    }

    @Test func everyFormatStringFormats() throws {
        for (key, format) in try Self.table("en") {
            let placeholders = Self.placeholders(format)
            guard !placeholders.isEmpty else { continue }
            let arguments: [any CVarArg] = placeholders.map { placeholder -> any CVarArg in
                if placeholder.conversion == "@" { return "‹\(placeholder.position)›" }
                return 4_200 + placeholder.position
            }
            let text = String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: arguments)
            #expect(!text.contains("%"), "\(key) left a placeholder: \(text)")
            for placeholder in placeholders {
                #expect(text.contains(placeholder.conversion == "@" ? "‹\(placeholder.position)›" : "\(4_200 + placeholder.position)"),
                        "\(key) dropped \(placeholder)")
            }
        }
    }

    // MARK: - Translations

    @Test func translationsHaveTheEnglishKeysAndPlaceholders() throws {
        let english = try Self.table("en")
        #expect(Self.languages.contains("en"))
        for language in Self.languages where language != "en" {
            let translation = try Self.table(language)
            let missing = Set(english.keys).subtracting(translation.keys).filter { !Self.isAwaitingTranslation($0) }
            let extra = Set(translation.keys).subtracting(english.keys)
            #expect(missing.isEmpty, "\(language).lproj lacks \(missing.sorted())")
            #expect(extra.isEmpty, "\(language).lproj has keys en.lproj doesn't: \(extra.sorted())")
            for (key, value) in translation {
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): empty text for \(key)")
                guard let source = english[key] else { continue }
                #expect(Self.placeholders(value) == Self.placeholders(source),
                        "\(language) \(key): placeholders \(Self.placeholders(value)) instead of \(Self.placeholders(source))")
            }
        }
    }

    /// Every text numbers all of its placeholders or none, in every language: a translation of
    /// "%1$@ and %2$@" as "%2$@ and %@" would otherwise pass the placeholder comparison above.
    @Test func placeholdersAreAllNumberedOrAllPlain() throws {
        for language in Self.languages {
            for (key, value) in try Self.table(language) {
                #expect(!Self.mixesNumberedAndPlainPlaceholders(value), "\(language) \(key) mixes numbered and plain placeholders: \(value)")
            }
        }
    }

    @Test func mixedPlaceholdersAreCaught() {
        #expect(Self.mixesNumberedAndPlainPlaceholders("%2$@ and %@"))
        #expect(Self.mixesNumberedAndPlainPlaceholders("%@ has %2$ld apps"))
        #expect(!Self.mixesNumberedAndPlainPlaceholders("%1$@ has %2$ld apps"))
        #expect(!Self.mixesNumberedAndPlainPlaceholders("%@ has %ld apps"))
        #expect(!Self.mixesNumberedAndPlainPlaceholders("100%% of %1$@"))
        #expect(!Self.mixesNumberedAndPlainPlaceholders("No placeholders"))
        // The comparison alone can't tell these apart.
        #expect(Self.placeholders("%2$@ and %@") == Self.placeholders("%1$@ and %2$@"))
    }

    /// Every key awaiting translation is in the English table, so the prefixes don't hide a typo.
    @Test func keysAwaitingTranslationAreEnglishKeys() throws {
        let english = try Self.table("en")
        for prefix in Self.awaitingTranslation {
            #expect(english.keys.contains { $0.hasPrefix(prefix) }, "no en.lproj key starts with \(prefix)")
        }
    }

    // MARK: - Lookup

    @Test func missingTablesAndKeysFallBackToEnglish() {
        #expect(Localization.string("test.missing.key", "Fallback text") == "Fallback text")
        #expect(Localization.format("test.missing.format", "%1$@ has %2$ld apps", "Work", 3) == "Work has 3 apps")
        // Numbered placeholders let a translation reorder the values.
        #expect(Localization.format("test.missing.reordered", "%2$@ · %1$@", "first", "second") == "second · first")
    }

    @Test func lookupReadsTheBundlesTable() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let folder = temporary.url.appending(components: "Test.bundle", "Contents", "Resources", "en.lproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("\"test.greeting\" = \"Hello from the table\";\n".utf8).write(to: folder.appending(path: "Localizable.strings"))
        let info = ["CFBundleIdentifier": "com.cybokron.limitguard.l10n-test", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: temporary.url.appending(components: "Test.bundle", "Contents", "Info.plist"))
        let bundle = try #require(Bundle(url: temporary.url.appending(path: "Test.bundle", directoryHint: .isDirectory)))

        #expect(Localization.string("test.greeting", "English default", in: bundle) == "Hello from the table")
        #expect(Localization.string("test.absent", "English default", in: bundle) == "English default")
    }
}
