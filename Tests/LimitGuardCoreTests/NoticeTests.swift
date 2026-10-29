import Foundation
import Testing
@testable import LimitGuardCore

/// The first-run notice: its text is the spec's, word for word.
@Suite("Notice text")
struct NoticeTextTests {
    /// The notice section of the spec: the bold title line and the quoted body, joined into one paragraph.
    private func specText() throws -> (title: String, body: String) {
        let spec = LocalizationTests.root.appending(path: "docs/design/limit-guard-spec.md")
        let lines = try String(contentsOf: spec, encoding: .utf8).components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("### 4.3.1") })
        let quoted = lines[(start + 1)...].prefix { !$0.hasPrefix("###") }
            .filter { $0.hasPrefix(">") }
            .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
        let title = try #require(quoted.first).replacingOccurrences(of: "**", with: "")
        return (title, quoted.dropFirst().joined(separator: " "))
    }

    @Test func noticeTextMatchesSpec() throws {
        let spec = try specText()
        let english = try LocalizationTests.table("en")
        #expect(english["notice.title"] == spec.title)
        #expect(english["notice.body"] == spec.body)
        #expect(spec.body.hasPrefix("This is an independent, open-source tool."))
    }
}
