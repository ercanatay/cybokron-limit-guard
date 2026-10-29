import Foundation

/// The text the continue language is guessed from (spec §7.5).
public enum LanguageSample {
    static let messageCount = 3
    /// A message shorter than this is too short for language recognition; it is kept apart, after the
    /// longer ones, only to be matched against the continue words ("devam et").
    static let minRecognisableLength = 20
    /// How many recent user messages the scanner reads, so that 3 long ones are found behind short replies.
    public static let scanCount = 20
    static let maxMessageLength = 4_000
    static let maxSampleLength = 1_000

    /// The last 3 real user messages of at least 20 characters, oldest first, joined by newlines and
    /// cut to 1000 characters, then the last 3 shorter ones (for `ContinueText`'s word match).
    /// Injected blocks are skipped: anything starting with a `<` tag (`<environment_context>`,
    /// `<user_instructions>`, …), AGENTS.md instructions and messages over 4000 characters.
    public static func extract(from userMessages: [String]) -> String {
        let real = userMessages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(isReal)
        let long = real.filter { $0.count >= minRecognisableLength }.suffix(messageCount)
        let short = real.filter { $0.count < minRecognisableLength }.suffix(messageCount)
        let head = String(long.joined(separator: "\n").prefix(maxSampleLength))
        return ([head] + short).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Whether a (trimmed) user message is something the owner typed rather than an injected block.
    static func isReal(_ message: String) -> Bool {
        !message.isEmpty && !message.hasPrefix("<") && !message.hasPrefix("# AGENTS.md instructions")
            && message.count <= maxMessageLength
    }
}
