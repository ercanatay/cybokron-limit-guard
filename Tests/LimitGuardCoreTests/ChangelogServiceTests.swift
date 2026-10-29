import Foundation
import Testing
@testable import LimitGuardCore

/// Release list JSON shaped like GitHub's `GET /repos/{owner}/{repo}/releases?per_page=30` answer
/// (fields trimmed; v0.6.0 and v0.5.9 as GitHub returned them), listed out of date order on purpose.
enum ChangelogFixtures {
    static let releases = """
    [
      {
        "url": "https://api.github.com/repos/ercanatay/cybokron-limit-guard/releases/416727700",
        "html_url": "https://github.com/ercanatay/cybokron-limit-guard/releases/tag/v0.6.0",
        "id": 416727700,
        "author": {"login": "github-actions[bot]"},
        "tag_name": "v0.6.0",
        "target_commitish": "main",
        "name": "v0.6.0",
        "draft": false,
        "immutable": false,
        "prerelease": false,
        "created_at": "2026-10-18T21:34:33Z",
        "updated_at": "2026-10-18T21:38:51Z",
        "published_at": "2026-10-18T21:38:51Z",
        "assets": [
          {"name": "Cybokron-Limit-Guard-0.6.0-universal.dmg", "state": "uploaded", "size": 4227621,
           "digest": "sha256:c0769abd4de0def6e254eec162e15b39f356f916d5c5bbdba4f71b3839056f4e",
           "browser_download_url": "https://github.com/ercanatay/cybokron-limit-guard/releases/download/v0.6.0/Cybokron-Limit-Guard-0.6.0-universal.dmg"}
        ],
        "body": "**Full Changelog**: https://github.com/ercanatay/cybokron-limit-guard/compare/v0.5.9...v0.6.0"
      },
      {
        "html_url": "https://github.com/ercanatay/cybokron-limit-guard/releases/tag/v0.7.0-beta.1",
        "tag_name": "v0.7.0-beta.1",
        "name": "Changelog pane beta",
        "draft": false,
        "prerelease": true,
        "published_at": "2026-10-20T08:00:00Z",
        "assets": [],
        "body": "<!-- Release notes generated using configuration in .github/release.yml -->\\r\\n## What's Changed\\r\\n* Settings → Changelog by @ercanatay in https://github.com/ercanatay/cybokron-limit-guard/pull/9\\r\\n  * nested item\\r\\n\\r\\n```sh\\r\\nscripts/test.sh\\r\\n```"
      },
      {
        "html_url": "https://github.com/ercanatay/cybokron-limit-guard/releases/tag/v0.5.8",
        "tag_name": "v0.5.8",
        "name": "v0.5.8",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-10-18T19:44:58Z",
        "body": null
      },
      {
        "html_url": "https://github.com/ercanatay/cybokron-limit-guard/releases/tag/v0.5.9",
        "tag_name": "v0.5.9",
        "name": "v0.5.9",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-10-18T20:31:14Z",
        "body": "   \\n"
      },
      {"tag_name": "v0.8.0", "name": "Draft", "draft": true, "prerelease": false, "published_at": null, "body": "Not yet"},
      {"tag_name": "nightly", "draft": false, "prerelease": true, "published_at": "2026-10-21T00:00:00Z", "body": "x"},
      {"name": "no tag at all"}
    ]
    """

    static var data: Data { Data(releases.utf8) }

    static func releaseList() throws -> [ReleaseInfo] {
        try ReleaseInfo.decodeList(from: data)
    }

    static func date(_ text: String) -> Date {
        try! Date(text, strategy: .iso8601)
    }
}

/// A `ChangelogFetching` that answers from a queue and records the ETags it was sent.
final class FakeChangelogFeed: ChangelogFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<ChangelogFetchResult, Error>]
    private var etags: [String?] = []

    init(_ answers: [Result<ChangelogFetchResult, Error>]) {
        self.answers = answers
    }

    /// The `If-None-Match` of every request, in order.
    var sentETags: [String?] { lock.withLock { etags } }
    var requestCount: Int { sentETags.count }

    func releases(ifNoneMatch etag: String?) async throws -> ChangelogFetchResult {
        let answer = lock.withLock { () -> Result<ChangelogFetchResult, Error> in
            etags.append(etag)
            return answers.isEmpty ? .failure(UpdateCheckError.network("no answer queued")) : answers.removeFirst()
        }
        return try answer.get()
    }
}

@Suite("Changelog")
struct ChangelogTests {
    private func version(_ text: String) -> SemanticVersion {
        SemanticVersion(text)!
    }

    private func entry(_ tag: String, published: String? = nil, prerelease: Bool = false, notes: String = "") -> ChangelogEntry {
        ChangelogEntry(
            tagName: tag,
            version: version(tag),
            name: tag,
            notes: notes,
            publishedAt: published.map(ChangelogFixtures.date),
            isPrerelease: prerelease
        )
    }

    // MARK: - Decoding and order

    @Test func decodesTheReleaseListNewestFirstWithPrereleasesWithoutDrafts() throws {
        let entries = ChangelogService.entries(from: try ChangelogFixtures.releaseList())

        // The draft, the tag that isn't a version and the entry without a tag are left out; the
        // prerelease stays (it gets a badge).
        #expect(entries.map(\.tagName) == ["v0.7.0-beta.1", "v0.6.0", "v0.5.9", "v0.5.8"])
        let beta = entries[0]
        #expect(beta.isPrerelease)
        #expect(beta.title == "Changelog pane beta")
        #expect(beta.publishedAt == ChangelogFixtures.date("2026-10-20T08:00:00Z"))
        let latest = entries[1]
        #expect(latest.version == version("0.6.0"))
        #expect(!latest.isPrerelease)
        #expect(latest.title == nil, "named after its tag")
        #expect(latest.pageURL?.absoluteString == "https://github.com/ercanatay/cybokron-limit-guard/releases/tag/v0.6.0")
        #expect(latest.notes.hasPrefix("**Full Changelog**"))
        #expect(latest.publishedAt == ChangelogFixtures.date("2026-10-18T21:38:51Z"))
    }

    @Test func sortsByPublicationDateThenVersion() {
        let sorted = ChangelogService.sorted([
            entry("v0.5.0", published: "2026-10-17T13:24:51Z"),
            entry("v0.4.0"),
            entry("v0.6.0", published: "2026-10-18T21:38:51Z"),
            // Published at the same moment: the higher version first.
            entry("v0.5.2", published: "2026-10-18T09:36:05Z"),
            entry("v0.5.10", published: "2026-10-18T09:36:05Z"),
            entry("v0.3.0"),
        ])
        #expect(sorted.map(\.tagName) == ["v0.6.0", "v0.5.10", "v0.5.2", "v0.5.0", "v0.4.0", "v0.3.0"])
    }

    @Test func oneEntryPerVersion() {
        let releases = [
            ReleaseInfo(tagName: "v0.6.0", version: version("0.6.0"), notes: "first"),
            ReleaseInfo(tagName: "0.6.0", version: version("0.6.0"), notes: "second"),
        ]
        #expect(ChangelogService.entries(from: releases).map(\.notes) == ["first"])
    }

    // MARK: - Badges

    @Test func latestIsTheNewestReleaseThatIsntAPrerelease() throws {
        let entries = ChangelogService.entries(from: try ChangelogFixtures.releaseList())
        let badges = { (current: SemanticVersion?) in
            entries.map { ChangelogService.badges(for: $0, in: entries, currentVersion: current) }
        }

        #expect(badges(version("0.5.9")) == [.prerelease, .latest, .installed, []])
        #expect(badges(version("0.6.0")) == [.prerelease, [.latest, .installed], [], []])
        #expect(badges(version("0.7.0-beta.1")) == [[.prerelease, .installed], .latest, [], []])
        // A version that isn't listed, or none at all (e.g. `swift run`): nothing is installed.
        #expect(badges(version("0.4.0")) == [.prerelease, .latest, [], []])
        #expect(badges(nil) == [.prerelease, .latest, [], []])
        // Build metadata doesn't make it another version.
        #expect(badges(version("0.6.0+42"))[1] == [.latest, .installed])
    }

    // MARK: - Notes

    @Test func releasesWithoutNotesFallBackToTheNoNotesText() throws {
        let entries = ChangelogService.entries(from: try ChangelogFixtures.releaseList())
        let byTag = Dictionary(uniqueKeysWithValues: entries.map { ($0.tagName, $0) })

        #expect(byTag["v0.6.0"]?.hasNotes == true)
        #expect(byTag["v0.7.0-beta.1"]?.hasNotes == true)
        // Only whitespace, or `null`: the pane shows "No release notes for this version." instead.
        #expect(byTag["v0.5.9"]?.hasNotes == false)
        #expect(byTag["v0.5.9"]?.noteBlocks == [])
        #expect(byTag["v0.5.8"]?.notes == "")
        #expect(byTag["v0.5.8"]?.hasNotes == false)
        #expect(entry("v1.0.0", notes: "<!-- generated -->\n\n").hasNotes == false)
    }

    @Test func notesBecomeHeadingsListsParagraphsAndCode() {
        let notes = """
        <!-- Release notes generated using configuration in .github/release.yml -->
        ## What's Changed ##
        * **Changelog** pane by @ercanatay in https://github.com/ercanatay/cybokron-limit-guard/pull/9
          - nested item
            that goes on
        1. first
        12) twelfth

        #12 isn't a heading, and
        this line goes on.
        > quoted

        ---
        ```swift
        let x = 1
        ```
        ### Fixed
        + Plus item
        """
        #expect(ReleaseNotesMarkdown.blocks(notes) == [
            .heading(level: 2, text: "What's Changed"),
            .listItem(marker: "•", depth: 0, text: "**Changelog** pane by @ercanatay in https://github.com/ercanatay/cybokron-limit-guard/pull/9"),
            .listItem(marker: "•", depth: 1, text: "nested item that goes on"),
            .listItem(marker: "1.", depth: 0, text: "first"),
            .listItem(marker: "12.", depth: 0, text: "twelfth"),
            .paragraph("#12 isn't a heading, and\nthis line goes on.\nquoted"),
            .rule,
            .code("let x = 1"),
            .heading(level: 3, text: "Fixed"),
            .listItem(marker: "•", depth: 0, text: "Plus item"),
        ])
    }

    @Test func notesWithWindowsLineEndingsAndAnOpenCodeBlock() {
        #expect(ReleaseNotesMarkdown.blocks("# Title\r\n- a\r\n```\r\nraw `code`\r\n") == [
            .heading(level: 1, text: "Title"),
            .listItem(marker: "•", depth: 0, text: "a"),
            .code("raw `code`"),
        ])
        #expect(ReleaseNotesMarkdown.blocks("") == [])
        #expect(ReleaseNotesMarkdown.blocks("#\n-\n  \n") == [.paragraph("#\n-")])
    }

    @Test func inlineMarkdownKeepsWebLinksOnly() {
        let text = ReleaseNotesMarkdown.inline("**Full Changelog**: https://github.com/a/b/compare/v1...v2 · [docs](https://cybokron.com) · [file](file:///etc/hosts) · `code`")
        let runs = text.runs.map { (String(text[$0.range].characters), $0.link, $0.inlinePresentationIntent) }

        #expect(String(text.characters) == "Full Changelog: https://github.com/a/b/compare/v1...v2 · docs · file · code")
        #expect(runs.contains { $0.0 == "Full Changelog" && $0.2 == .stronglyEmphasized })
        #expect(runs.contains { $0.0 == "https://github.com/a/b/compare/v1...v2" && $0.1 == URL(string: "https://github.com/a/b/compare/v1...v2") })
        #expect(runs.contains { $0.0 == "docs" && $0.1 == URL(string: "https://cybokron.com") })
        #expect(runs.contains { $0.0 == "code" && $0.2 == .code })
        #expect(runs.allSatisfy { $0.1?.isFileURL != true }, "a file link isn't clickable")
    }

    // MARK: - Cache file

    @Test func cacheRoundTripsAndToleratesDamage() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let persistence = JSONFileChangelogCachePersistence(fileURL: temporary.url.appending(path: "changelog-cache.json"))
        #expect(persistence.load() == nil, "no file yet")

        let cache = ChangelogCache(
            fetchedAt: Date(timeIntervalSince1970: 1_792_000_000),
            etag: #"W/"361a397e""#,
            entries: ChangelogService.entries(from: try ChangelogFixtures.releaseList())
        )
        try persistence.save(cache)
        #expect(persistence.load() == cache)

        try Data("not json".utf8).write(to: persistence.fileURL)
        #expect(persistence.load() == nil)

        // Entries that can't be read are dropped; a missing date counts as 1970.
        try Data("""
        {"entries": [{"tagName": "v0.6.0", "notes": "ok"}, {"tagName": "nightly"}, {"notes": "no tag"}]}
        """.utf8).write(to: persistence.fileURL)
        let damaged = try #require(persistence.load())
        #expect(damaged.entries.map(\.tagName) == ["v0.6.0"])
        #expect(damaged.fetchedAt == Date(timeIntervalSince1970: 0))
        #expect(damaged.etag == nil)
    }

    // MARK: - Feed

    @Test func feedSendsTheETagAndReadsTheAnswer() async throws {
        let session = StubURLProtocol.makeSession()
        let url = StubURLProtocol.register(.init(body: ChangelogFixtures.data, headers: ["ETag": #"W/"abc""#]), fileName: "releases")
        let feed = GitHubChangelogFeed(url: url, appVersion: "0.6.0", session: session)

        guard case .releases(let releases, let etag) = try await feed.releases(ifNoneMatch: #"W/"old""#) else {
            Issue.record("expected releases")
            return
        }
        #expect(releases.map(\.tagName) == ["v0.6.0", "v0.7.0-beta.1", "v0.5.8", "v0.5.9", "v0.8.0"])
        #expect(etag == #"W/"abc""#)
        let request = try #require(StubURLProtocol.request(for: url))
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == #"W/"old""#)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CybokronLimitGuard/0.6.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")

        let first = StubURLProtocol.register(.init(body: Data("[]".utf8)), fileName: "releases")
        _ = try await GitHubChangelogFeed(url: first, appVersion: "0.6.0", session: session).releases(ifNoneMatch: nil)
        #expect(StubURLProtocol.request(for: first)?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func feedReportsNotModifiedAndErrors() async {
        func feed(_ response: StubURLProtocol.Response) -> GitHubChangelogFeed {
            GitHubChangelogFeed(url: StubURLProtocol.register(response, fileName: "releases"), appVersion: "0.6.0", session: StubURLProtocol.makeSession())
        }
        let unchanged = try? await feed(.init(status: 304)).releases(ifNoneMatch: #"W/"abc""#)
        guard case .notModified? = unchanged else {
            Issue.record("expected notModified, got \(String(describing: unchanged))")
            return
        }
        // A 304 to a request without an ETag isn't an answer.
        await #expect(throws: UpdateCheckError.httpStatus(304)) { try await feed(.init(status: 304)).releases(ifNoneMatch: nil) }
        await #expect(throws: UpdateCheckError.rateLimited) { try await feed(.init(status: 403)).releases(ifNoneMatch: nil) }
        await #expect(throws: UpdateCheckError.rateLimited) { try await feed(.init(status: 429)).releases(ifNoneMatch: "x") }
        await #expect(throws: UpdateCheckError.httpStatus(500)) { try await feed(.init(status: 500)).releases(ifNoneMatch: nil) }
        await #expect(throws: UpdateCheckError.self) { try await feed(.init(body: Data("{}".utf8))).releases(ifNoneMatch: nil) }
    }

    @Test func feedURLCanBePointedAtATestServer() {
        let variable = GitHubChangelogFeed.urlOverrideVariable
        #expect(GitHubChangelogFeed.resolvedURL(environment: [:]) == UpdateLinks.changelogReleasesAPI)
        #expect(UpdateLinks.changelogReleasesAPI.absoluteString
            == "https://api.github.com/repos/ercanatay/cybokron-limit-guard/releases?per_page=30")
        #expect(GitHubChangelogFeed.resolvedURL(environment: [variable: " http://127.0.0.1:8765/releases.json "]).absoluteString
            == "http://127.0.0.1:8765/releases.json")
        #expect(GitHubChangelogFeed.resolvedURL(environment: [variable: "file:///etc/hosts"]) == UpdateLinks.changelogReleasesAPI)
    }
}

/// `ChangelogService`: what the pane shows from the cache and after each kind of refresh.
@MainActor
@Suite("Changelog service")
struct ChangelogServiceTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_792_400_000)
    }

    private let temporary: TemporaryDirectory
    private let persistence: JSONFileChangelogCachePersistence
    private let clock = Clock()

    init() throws {
        temporary = try TemporaryDirectory()
        persistence = JSONFileChangelogCachePersistence(fileURL: temporary.url.appending(path: "changelog-cache.json"))
    }

    private func service(_ feed: FakeChangelogFeed, current: String? = "0.5.9") -> ChangelogService {
        let clock = clock
        return ChangelogService(
            fetcher: feed,
            persistence: persistence,
            currentVersion: current.flatMap(SemanticVersion.init),
            now: { clock.now }
        )
    }

    private func savedCache(age: TimeInterval, etag: String? = #"W/"saved""#) throws -> ChangelogCache {
        // Saved in the order GitHub listed them, not newest first.
        let entries = try ChangelogFixtures.releaseList().filter { !$0.isDraft }.map(ChangelogEntry.init)
        let cache = ChangelogCache(fetchedAt: clock.now.addingTimeInterval(-age), etag: etag, entries: entries)
        try persistence.save(cache)
        return cache
    }

    @Test func showsTheSavedCopyAtOnceNewestFirst() throws {
        defer { temporary.remove() }
        let saved = try savedCache(age: 60)
        let feed = FakeChangelogFeed([])

        let changelog = service(feed)

        #expect(changelog.entries.map(\.tagName) == ["v0.7.0-beta.1", "v0.6.0", "v0.5.9", "v0.5.8"])
        #expect(changelog.lastUpdated == saved.fetchedAt)
        #expect(!changelog.isRefreshing)
        #expect(changelog.refreshError == nil)
        #expect(changelog.badges(for: changelog.entries[2]) == .installed)
        #expect(feed.requestCount == 0, "reading the cache asks nothing")
    }

    @Test func refreshReplacesAndSavesTheList() async throws {
        defer { temporary.remove() }
        let feed = FakeChangelogFeed([.success(.releases(try ChangelogFixtures.releaseList(), etag: #"W/"new""#))])
        let changelog = service(feed)
        #expect(changelog.entries.isEmpty)
        #expect(changelog.lastUpdated == nil)

        let refresh = changelog.refresh()
        #expect(changelog.isRefreshing)
        await refresh.value

        #expect(!changelog.isRefreshing)
        #expect(changelog.entries.map(\.tagName) == ["v0.7.0-beta.1", "v0.6.0", "v0.5.9", "v0.5.8"])
        #expect(changelog.lastUpdated == clock.now)
        #expect(changelog.refreshError == nil)
        #expect(feed.sentETags == [nil])
        let saved = try #require(persistence.load())
        #expect(saved.entries == changelog.entries)
        #expect(saved.etag == #"W/"new""#)
        #expect(saved.fetchedAt == clock.now)

        // A new service (the next launch) starts from what was saved.
        #expect(service(FakeChangelogFeed([])).entries == changelog.entries)
    }

    @Test func unchangedListKeepsTheEntriesAndRenewsTheDate() async throws {
        defer { temporary.remove() }
        let saved = try savedCache(age: 3_600)
        let feed = FakeChangelogFeed([.success(.notModified)])
        let changelog = service(feed)
        let before = changelog.entries

        await changelog.refresh().value

        #expect(feed.sentETags == [#"W/"saved""#])
        #expect(changelog.entries == before)
        #expect(changelog.lastUpdated == clock.now)
        #expect(changelog.refreshError == nil)
        #expect(persistence.load()?.fetchedAt == clock.now)
        #expect(persistence.load()?.etag == saved.etag)
    }

    @Test func failedRefreshKeepsTheSavedCopyAndSaysWhy() async throws {
        defer { temporary.remove() }
        let saved = try savedCache(age: 3_600)
        let feed = FakeChangelogFeed([
            .failure(UpdateCheckError.rateLimited),
            .success(.notModified),
        ])
        let changelog = service(feed)

        await changelog.refresh().value

        #expect(changelog.entries.count == 4)
        #expect(changelog.lastUpdated == saved.fetchedAt)
        #expect(changelog.refreshError == UpdateCheckError.rateLimited.localizedDescription)
        #expect(persistence.load()?.fetchedAt == saved.fetchedAt, "the cache file is left alone")

        // The next success clears the error.
        await changelog.refresh().value
        #expect(changelog.refreshError == nil)
    }

    @Test func withoutEntriesTheWholeListIsAskedFor() async throws {
        defer { temporary.remove() }
        try persistence.save(ChangelogCache(fetchedAt: clock.now, etag: #"W/"empty""#, entries: []))
        let feed = FakeChangelogFeed([.success(.releases([], etag: nil))])

        await service(feed).refresh().value

        #expect(feed.sentETags == [nil])
    }

    @Test func showingThePaneRefreshesOnlyWhenTheCopyIsOld() async throws {
        defer { temporary.remove() }
        _ = try savedCache(age: ChangelogService.automaticRefreshInterval - 60)
        let feed = FakeChangelogFeed([.failure(UpdateCheckError.network("offline")), .success(.notModified)])
        let changelog = service(feed)

        #expect(changelog.refreshIfStale() == nil)
        #expect(feed.requestCount == 0, "a recent copy is shown as it is")

        clock.now.addTimeInterval(120)
        await changelog.refreshIfStale()?.value
        #expect(feed.requestCount == 1)
        #expect(changelog.refreshError != nil)

        // A failed try counts as a try: no new request right away, only after the interval.
        clock.now.addTimeInterval(60)
        #expect(changelog.refreshIfStale() == nil)
        clock.now.addTimeInterval(ChangelogService.automaticRefreshInterval)
        await changelog.refreshIfStale()?.value
        #expect(feed.requestCount == 2)
        #expect(changelog.refreshError == nil)
    }

    @Test func refreshesDontOverlap() async throws {
        defer { temporary.remove() }
        let feed = FakeChangelogFeed([.success(.releases(try ChangelogFixtures.releaseList(), etag: nil))])
        let changelog = service(feed)

        let first = changelog.refresh()
        let second = changelog.refresh()
        await first.value
        await second.value

        #expect(feed.requestCount == 1)
        #expect(changelog.entries.count == 4)
    }
}

/// `ReleaseNotesMarkdown` on large or hostile notes: HTML comments are removed in one pass (the
/// same result the old lazy regular expression gave), list items and code blocks grow without
/// copying, and notes past `maximumLength` are cut with a note.
@Suite("Release notes size and speed")
struct ReleaseNotesBoundsTests {
    /// 100,000 characters each, built to be slow for a quadratic step: comments that never close,
    /// many short comments, one list item of 20,000 lines, one code block of 20,000 lines.
    static let slowNotes: [(name: String, text: String)] = [
        ("unclosed comments", String(repeating: "<!--x", count: 20_000)),
        ("closed comments", String(repeating: "ab<!--x-->", count: 10_000)),
        ("long list item", "- start\n" + String(repeating: "more\n", count: 20_000)),
        ("long code block", "```\n" + String(repeating: "code\n", count: 20_000)),
    ]

    /// What the previous implementation did, with `--!>` also ending a comment as it does in HTML.
    static func regexRemovingComments(_ text: String) -> String {
        text.replacingOccurrences(of: #"<!--[\s\S]*?(?:-->|--!>)"#, with: "", options: .regularExpression)
    }

    @Test func commentsAlsoEndAtBangClose() {
        #expect(ReleaseNotesMarkdown.removingHTMLComments(from: "<!-- hello --!> world") == " world")
        // Whichever end comes first closes the comment.
        #expect(ReleaseNotesMarkdown.removingHTMLComments(from: "<!-- a --> b --!> c") == " b --!> c")
        #expect(ReleaseNotesMarkdown.removingHTMLComments(from: "<!-- a --!> b --> c") == " b --> c")
        #expect(ReleaseNotesMarkdown.removingHTMLComments(from: "<!-- x") == "<!-- x")
        #expect(ReleaseNotesMarkdown.removingHTMLComments(from: "a --!> b") == "a --!> b")
    }

    @Test func commentsAreRemovedAsBefore() {
        let cases = [
            "a<!-- x -->b<!--\n-->c",
            "a<!-- open",
            "a<!--x-->b<!--c",
            "a<!--x-->b<!-- open <!-- y -->c",
            "<!---->",
            "<!-->",
            "-->a<!--",
            "a<!--x--!-->b",
            "<!---!>",
            "<!--!>",
            "",
        ]
        for text in cases {
            #expect(ReleaseNotesMarkdown.removingHTMLComments(from: text) == Self.regexRemovingComments(text), "\(text)")
        }
        // Random mixes of the pieces that matter, against the regular expression.
        var generator = SystemRandomNumberGenerator()
        let pieces = ["<!--", "-->", "--!>", "<!-", "--", "!", ">", "a", "\n", " "]
        for _ in 0..<500 {
            let text = (0..<Int.random(in: 0...24, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            #expect(ReleaseNotesMarkdown.removingHTMLComments(from: text) == Self.regexRemovingComments(text), "\(text.debugDescription)")
        }
    }

    @Test func aHundredThousandCharactersOfHostileNotesAreQuick() {
        let clock = ContinuousClock()
        let bound: Duration = ProcessInfo.processInfo.environment["CI"] != nil ? .seconds(1) : .milliseconds(200)
        for notes in Self.slowNotes {
            #expect(notes.text.count >= 100_000)
            var blocks: [ReleaseNotesBlock] = []
            let elapsed = clock.measure {
                blocks = ReleaseNotesMarkdown.blocks(notes.text)
            }
            // CI runners vary; 1 s still catches the quadratic regression.
            #expect(elapsed < bound, "\(notes.name): \(elapsed)")
            #expect(!blocks.isEmpty, "\(notes.name)")
        }
    }

    @Test func longListItemsAndCodeBlocksKeepEveryLine() throws {
        let item = try #require(ReleaseNotesMarkdown.blocks("- start\n" + String(repeating: "more\n", count: 1_000)).first)
        #expect(item == .listItem(marker: "•", depth: 0, text: (["start"] + Array(repeating: "more", count: 1_000)).joined(separator: " ")))
        let code = try #require(ReleaseNotesMarkdown.blocks("```\n" + String(repeating: "code\n", count: 1_000) + "```").first)
        #expect(code == .code(Array(repeating: "code", count: 1_000).joined(separator: "\n")))
    }

    @Test func notesPastTheLimitAreCutWithANote() throws {
        let limit = ReleaseNotesMarkdown.maximumLength
        #expect(limit == 250_000)
        let long = String(repeating: "word ", count: 60_000)

        let blocks = ReleaseNotesMarkdown.blocks(long)
        #expect(blocks.last == .paragraph(ReleaseNotesMarkdown.truncationNote))
        if case .paragraph(let text)? = blocks.first {
            #expect(text.count <= limit)
        } else {
            Issue.record("no paragraph: \(blocks.prefix(1))")
        }
        let compact = String(try #require(ReleaseNotesMarkdown.compact(long)).characters)
        #expect(compact.hasSuffix(ReleaseNotesMarkdown.truncationNote))
        #expect(compact.count <= limit + ReleaseNotesMarkdown.truncationNote.count + 2)
        #expect(ReleaseNotesMarkdown.truncationNote == "The release notes are longer than shown here; the release page has all of them.")
    }

    @Test func theLimitCountsCharactersNotBytes() {
        let limit = ReleaseNotesMarkdown.maximumLength
        #expect(!ReleaseNotesMarkdown.bounded(String(repeating: "a", count: limit)).isTruncated)
        // Two UTF-8 bytes each: more bytes than the limit, but not more characters.
        let accented = String(repeating: "é", count: limit)
        #expect(!ReleaseNotesMarkdown.bounded(accented).isTruncated)
        let cut = ReleaseNotesMarkdown.bounded(accented + "é")
        #expect(cut.isTruncated)
        #expect(cut.text.count == limit)
        // Short notes are untouched.
        #expect(ReleaseNotesMarkdown.blocks("- a") == [.listItem(marker: "•", depth: 0, text: "a")])
    }
}
