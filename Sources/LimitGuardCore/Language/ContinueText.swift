import Foundation
import NaturalLanguage

/// Picks the continue text for a thread's language (spec §7.5).
public enum ContinueText {
    static let minConfidence = 0.6

    /// `language` is the recognised code (e.g. "tr") when confidence is high enough, even if the table
    /// has no entry for it; nil when the sample was too short or ambiguous.
    public static func resolve(sample: String, table: [String: String], fallback: String) -> (text: String, language: String?) {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (fallback, nil) }
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        // The owner's own continue words, most recent first, say the language better than a guess.
        for line in lines.reversed() {
            if let code = languageOfContinueWord(line, table: table) {
                return (table[code] ?? fallback, code)
            }
        }
        // Very short messages are no basis for recognition; unless that is all there is.
        let recognisable = lines.filter { $0.count >= LanguageSample.minRecognisableLength }
        let basis = recognisable.isEmpty ? trimmed : recognisable.joined(separator: "\n")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(basis)
        guard let dominant = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant],
              confidence >= minConfidence
        else { return (fallback, nil) }
        let code = dominant.rawValue
        let text = table[code] ?? table[String(code.split(separator: "-").first ?? "")]
        return (text.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, code)
    }

    /// Extra words that count as a continue word for a language, for this match only.
    static let aliases: [String: [String]] = ["tr": ["devam"]]

    /// The table language whose continue text (or alias) `message` is: equal to it, or starting with
    /// it and followed by the end or punctuation ("devam et.", "continue!"), ignoring case and diacritics.
    static func languageOfContinueWord(_ message: String, table: [String: String]) -> String? {
        let text = fold(message)
        guard !text.isEmpty else { return nil }
        for code in table.keys.sorted() {
            let base = String(code.split(separator: "-").first ?? "")
            let words = ([table[code] ?? ""] + (aliases[base] ?? [])).map(fold).filter { !$0.isEmpty }
            for word in words where text.hasPrefix(word) {
                let rest = text.dropFirst(word.count)
                if rest.isEmpty || rest.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return code }
            }
        }
        return nil
    }

    private static func fold(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
    }
}
