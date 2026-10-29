import Foundation

/// A block of release notes as Settings → Changelog shows it. The text of headings, list items and
/// paragraphs is inline Markdown (bold, italics, links, `code`) for `ReleaseNotesMarkdown.inline(_:)`;
/// code blocks are kept as they are.
public enum ReleaseNotesBlock: Equatable, Sendable {
    /// `#` to `######`: `level` is 1 to 6.
    case heading(level: Int, text: String)
    /// A list item. `marker` is "•" for `-`, `*` and `+` items and the number of a numbered one
    /// ("2."); `depth` is 0 at the margin and grows by one for every two spaces of indentation.
    case listItem(marker: String, depth: Int, text: String)
    /// Consecutive lines of text (a blockquote's too), line breaks kept as GitHub shows them.
    case paragraph(String)
    /// The lines of a fenced code block (```` ``` ```` or `~~~`).
    case code(String)
    /// A thematic break: `---`, `***` or `___`.
    case rule
}

/// The Markdown subset of GitHub release notes that Settings → Changelog renders: headings, bullet
/// and numbered lists (nested by indentation), paragraphs, blockquotes, fenced code, rules, and the
/// inline syntax within them. Anything else shows as plain text; HTML comments (such as the one
/// GitHub's generated notes start with) are left out.
public enum ReleaseNotesMarkdown {
    /// The deepest list nesting shown; deeper items are drawn at this depth.
    public static let maximumListDepth = 4

    /// The most characters of release notes shown; longer notes are cut there and end with
    /// `truncationNote`. Every step below takes time in proportion to the length, and this keeps
    /// even that bounded.
    public static let maximumLength = 250_000

    /// What ends notes cut at `maximumLength`.
    public static var truncationNote: String {
        Localization.string("core.releaseNotes.truncated", "The release notes are longer than shown here; the release page has all of them.")
    }

    /// `notes`, cut to `maximumLength` characters, and whether anything was cut.
    static func bounded(_ notes: String) -> (text: String, isTruncated: Bool) {
        // Never more characters than UTF-8 bytes: most notes need no counting at all.
        guard notes.utf8.count > maximumLength,
              let end = notes.index(notes.startIndex, offsetBy: maximumLength, limitedBy: notes.endIndex),
              end < notes.endIndex
        else { return (notes, false) }
        return (String(notes[..<end]), true)
    }

    /// `markdown` cut into blocks; empty when there's nothing to show (no text, or only whitespace and
    /// HTML comments). Notes longer than `maximumLength` end with a `truncationNote` paragraph.
    public static func blocks(_ markdown: String) -> [ReleaseNotesBlock] {
        let (text, isTruncated) = bounded(markdown)
        var blocks: [ReleaseNotesBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?
        var fence = ""
        // A line right under a list item (no blank line between) continues the item; its lines
        // are collected here and joined once, when the item ends.
        var continuesListItem = false
        var listItemLines: [String] = []

        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        func endListItem() {
            continuesListItem = false
            guard !listItemLines.isEmpty, case .listItem(let marker, let depth, let text)? = blocks.last else { return }
            blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: ([text] + listItemLines).joined(separator: " "))
            listItemLines = []
        }

        for line in lines(of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if codeLines != nil {
                if isFence(trimmed, closing: fence) {
                    blocks.append(.code(codeLines!.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    // In place: copying the array for every line would take quadratic time.
                    codeLines!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                endListItem()
                endParagraph()
                fence = String(trimmed.prefix(3))
                codeLines = []
                continue
            }
            if trimmed.isEmpty {
                endListItem()
                endParagraph()
                continue
            }
            if let heading = heading(trimmed) {
                endListItem()
                endParagraph()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                endListItem()
                endParagraph()
                blocks.append(.rule)
                continue
            }
            if let item = listItem(line) {
                endListItem()
                endParagraph()
                blocks.append(item)
                continuesListItem = true
                continue
            }
            if continuesListItem {
                listItemLines.append(trimmed)
                continue
            }
            paragraph.append(trimmed.hasPrefix(">") ? unquoted(trimmed) : trimmed)
        }
        endListItem()
        endParagraph()
        // A code block that's never closed runs to the end (without the blank lines there).
        if var codeLines {
            while let last = codeLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                codeLines.removeLast()
            }
            if !codeLines.isEmpty {
                blocks.append(.code(codeLines.joined(separator: "\n")))
            }
        }
        if isTruncated {
            blocks.append(.paragraph(truncationNote))
        }
        return blocks.filter { block in
            if case .paragraph(let text) = block { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
            return true
        }
    }

    /// Inline Markdown as styled text: bold, italics, strikethrough, `code` and links (bare
    /// `https://` addresses become links too). Only `https` and `mailto` links stay clickable
    /// (`LinkPolicy.isClickable`); text that can't be parsed is shown as it is.
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let result = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        return LinkPolicy.removingUnclickableLinks(from: result)
    }

    /// The notes as one block of text, for the update window's small scrolling box: `## Title`
    /// becomes bold and `- item` / `* item` a bullet, so the inline Markdown renders. Links follow
    /// `inline(_:)`'s rule. `nil` when there are no notes. Notes longer than `maximumLength` end
    /// with `truncationNote`.
    public static func compact(_ notes: String) -> AttributedString? {
        let (bounded, isTruncated) = bounded(notes)
        let text = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var simplified = text
            .components(separatedBy: .newlines)
            .map(compactLine)
            .joined(separator: "\n")
        if isTruncated {
            simplified += "\n\n" + truncationNote
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: simplified, options: options) else {
            return AttributedString(text)
        }
        return LinkPolicy.removingUnclickableLinks(from: parsed)
    }

    /// `## Title` becomes bold, `- item` / `* item` a bullet.
    private static func compactLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "" : "**\(title)**"
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let indent = String(line.prefix { $0 == " " })
            return indent + "• " + trimmed.dropFirst(2)
        }
        return line
    }

    // MARK: - Lines

    /// The lines of `markdown`, any line ending, without HTML comments.
    private static func lines(of markdown: String) -> [String] {
        let normalized = removingHTMLComments(from: markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"))
        return normalized.components(separatedBy: "\n")
    }

    /// `text` without `<!-- … -->` comments, in one pass. As in HTML, a comment ends at the first
    /// `-->` or `--!>` after it, whichever comes first. A comment that's never closed stays as it
    /// is, and so does everything after it: once no end follows a `<!--`, none follows a later
    /// one either, so the scan stops there. (A lazy regular expression would look for the end
    /// again from every `<!--`, which takes quadratic time on text full of them.)
    static func removingHTMLComments(from text: String) -> String {
        var result = ""
        var rest = text[...]
        while let open = rest.firstRange(of: "<!--") {
            guard let close = commentEnd(in: rest[open.upperBound...]) else { break }
            result += rest[..<open.lowerBound]
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    /// The first `-->` or `--!>` in `text`. One scan finds whichever comes first; searching for
    /// each separately would read past the earlier one to the end of the text every time.
    private static func commentEnd(in text: Substring) -> Range<Substring.Index>? {
        var from = text.startIndex
        while let dashes = text[from...].firstRange(of: "--") {
            var end = dashes.upperBound
            if end < text.endIndex, text[end] == "!" { end = text.index(after: end) }
            if end < text.endIndex, text[end] == ">" { return dashes.lowerBound..<text.index(after: end) }
            // Not an end here; a match may still start at the second dash ("--->").
            from = text.index(after: dashes.lowerBound)
        }
        return nil
    }

    /// A line of only the fence's character, at least three of them: what closes a code block.
    private static func isFence(_ trimmed: String, closing fence: String) -> Bool {
        guard let character = fence.first, trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == character }
    }

    /// `## Title` (and `## Title ##`); a `#` without a space after it (`#12`) isn't a heading.
    private static func heading(_ trimmed: String) -> ReleaseNotesBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing sequence of #s.
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound])
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return text.isEmpty ? nil : .heading(level: hashes.count, text: text)
    }

    /// Three or more `-`, `*` or `_` (the same one), spaces allowed between them.
    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `- item`, `* item`, `+ item`, `1. item` or `1) item`, indented by any number of spaces.
    private static func listItem(_ line: String) -> ReleaseNotesBlock? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }
        let width = indentation.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(indentation.count)
        let marker: String
        let text: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            marker = "•"
            text = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let afterDigits = rest.dropFirst(digits.count)
            guard (1...9).contains(digits.count), let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
                  afterDigits.dropFirst().first == " "
            else { return nil }
            marker = "\(digits)."
            text = afterDigits.dropFirst(2)
        }
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .listItem(marker: marker, depth: min(width / 2, maximumListDepth), text: content)
    }

    /// A blockquote line without its `>` markers.
    private static func unquoted(_ trimmed: String) -> String {
        var text = Substring(trimmed)
        while text.first == ">" {
            text = text.dropFirst().drop { $0 == " " }
        }
        return String(text)
    }
}
