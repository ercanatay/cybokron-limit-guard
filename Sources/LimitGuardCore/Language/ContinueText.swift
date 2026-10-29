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
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant],
              confidence >= minConfidence
        else { return (fallback, nil) }
        let code = dominant.rawValue
        let text = table[code] ?? table[String(code.split(separator: "-").first ?? "")]
        return (text.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, code)
    }
}
