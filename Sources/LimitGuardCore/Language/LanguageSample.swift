import Foundation

/// The text the continue language is guessed from (spec §7.5).
public enum LanguageSample {
    static let messageCount = 3
    static let maxMessageLength = 4_000
    static let maxSampleLength = 1_000

    /// The last 3 real user messages, oldest first, joined by newlines and cut to 1000 characters.
    /// Injected blocks are skipped: anything starting with a `<` tag (`<environment_context>`,
    /// `<user_instructions>`, …), AGENTS.md instructions and messages over 4000 characters.
    public static func extract(from userMessages: [String]) -> String {
        let real = userMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { message in
                !message.isEmpty && !message.hasPrefix("<") && !message.hasPrefix("# AGENTS.md instructions")
                    && message.count <= maxMessageLength
            }
        return String(real.suffix(messageCount).joined(separator: "\n").prefix(maxSampleLength))
    }
}
