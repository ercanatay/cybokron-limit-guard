import Foundation
import Testing
@testable import LimitGuardCore

/// Release list JSON shaped like GitHub's `GET /repos/{owner}/{repo}/releases` answer (trimmed).
private enum ReleaseListFixtures {
    static func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, dmg: Bool = true, published: String = "2026-10-18T10:00:00Z") -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = dmg ? """
            [{"name": "Cybokron-Limit-Guard-\(version)-universal.dmg", "state": "uploaded", "size": 2500000,
              "browser_download_url": "https://github.com/ercanatay/cybokron-limit-guard/releases/download/\(tag)/Cybokron-Limit-Guard-\(version)-universal.dmg"}]
            """ : "[]"
        return """
            {"tag_name": "\(tag)", "draft": \(draft), "prerelease": \(prerelease), "published_at": "\(published)",
             "html_url": "https://github.com/ercanatay/cybokron-limit-guard/releases/tag/\(tag)", "assets": \(assets)}
            """
    }

    /// Out of order, with a draft, a prerelease, a tag that isn't a version, an entry without a
    /// tag, a release without a disk image and a duplicate.
    static let mixed = "[" + [
        release("v0.5.3", published: "2026-10-18T08:00:00Z"),
        release("v0.6.0", draft: true),
        release("v0.5.5", published: "2026-10-18T19:00:00Z"),
        release("v0.6.0-beta.1", prerelease: true),
        release("v0.5.7-rc.1"),
        release("nightly"),
        #"{"name": "no tag"}"#,
        release("v0.5.0", dmg: false, published: "2026-10-17T13:24:51Z"),
        release("v0.5.4"),
        release("0.5.4"),
    ].joined(separator: ",") + "]"
}

@Suite("Release history")
struct ReleaseHistoryTests {
    private func version(_ text: String) -> SemanticVersion {
        SemanticVersion(text)!
    }

    private var published: [ReleaseInfo] {
        ReleaseHistory.installable((try? ReleaseInfo.decodeList(from: Data(ReleaseListFixtures.mixed.utf8))) ?? [])
    }

    // MARK: - Parsing and filtering

    @Test func listSkipsEntriesThatArentReleases() throws {
        let releases = try ReleaseInfo.decodeList(from: Data(ReleaseListFixtures.mixed.utf8))
        // "nightly" and the entry without a tag are left out; everything else is read in order.
        #expect(releases.map(\.tagName) == ["v0.5.3", "v0.6.0", "v0.5.5", "v0.6.0-beta.1", "v0.5.7-rc.1", "v0.5.0", "v0.5.4", "0.5.4"])
        #expect(releases[1].isDraft)
        #expect(releases[3].isPrerelease)
        #expect(releases[0].publishedAt == ISO8601DateFormatter().date(from: "2026-10-18T08:00:00Z"))
    }

    @Test func listThatIsntAListIsAnError() {
        #expect(throws: UpdateCheckError.self) { try ReleaseInfo.decodeList(from: Data(ReleaseFixtures.v050.utf8)) }
        #expect(throws: UpdateCheckError.self) { try ReleaseInfo.decodeList(from: Data("not json".utf8)) }
        #expect((try? ReleaseInfo.decodeList(from: Data("[]".utf8)))?.isEmpty == true)
    }

    @Test func installableDropsDraftsPrereleasesAndDuplicatesNewestFirst() {
        #expect(published.map(\.version) == ["0.5.5", "0.5.4", "0.5.3", "0.5.0"].map(version))
        // The first listed of two releases with the same version wins.
        #expect(published[1].tagName == "v0.5.4")
        #expect(published.first { $0.version == version("0.5.0") }?.installerAsset == nil)
        #expect(published.first { $0.version == version("0.5.3") }?.installerAsset?.name == "Cybokron-Limit-Guard-0.5.3-universal.dmg")
    }

    @Test func versionChangeDirection() {
        #expect(ReleaseHistory.change(from: version("0.5.5"), to: version("0.5.3")) == .downgrade)
        #expect(ReleaseHistory.change(from: version("0.5.3"), to: version("0.5.10")) == .upgrade)
        #expect(ReleaseHistory.change(from: version("0.5.5"), to: version("v0.5.5")) == .reinstall)
        #expect(ReleaseHistory.change(from: version("0.9.9"), to: version("1.0.0")) == .upgrade)
        #expect(ReleaseHistory.versions(newerThan: version("0.5.3"), in: published) == [version("0.5.5"), version("0.5.4")])
        #expect(ReleaseHistory.versions(newerThan: version("0.5.5"), in: published).isEmpty)
    }

    // MARK: - Skipped versions after installing

    @Test func goingBackSkipsEveryNewerPublishedVersion() {
        let state = UpdateState(lastCheckDate: Date(timeIntervalSince1970: 1_000))

        let after = ReleaseHistory.state(state, afterInstalling: version("0.5.3"), over: version("0.5.5"), published: published)

        #expect(after.skippedVersions == ["0.5.5", "0.5.4"])
        #expect(after.isSkipped(version("0.5.5")))
        #expect(after.isSkipped(version("v0.5.4")))
        #expect(!after.isSkipped(version("0.5.3")))
        // Drafts and prereleases never get onto the list; a later release isn't skipped.
        #expect(!after.isSkipped(version("0.6.0")))
        #expect(!after.isSkipped(version("0.6.0-beta.1")))
        #expect(after.lastCheckDate == state.lastCheckDate)
    }

    @Test func goingBackAlsoSkipsTheVersionLeftBehindWhenItIsntListedYet() {
        // 0.5.6 runs but isn't published yet (its release is still a draft).
        let after = ReleaseHistory.state(UpdateState(), afterInstalling: version("0.5.4"), over: version("0.5.6"), published: published)
        #expect(after.skippedVersions == ["0.5.6", "0.5.5"])
        // A prerelease left behind isn't added.
        let fromBeta = ReleaseHistory.versionsSkipped(goingBackTo: version("0.5.4"), from: version("0.6.0-beta.1"), in: published)
        #expect(fromBeta == [version("0.5.5")])
    }

    @Test func goingBackKeepsEarlierSkipsThatAreStillNewer() {
        let state = UpdateState(skippedVersions: ["0.5.6", "0.5.1"])

        let after = ReleaseHistory.state(state, afterInstalling: version("0.5.4"), over: version("0.5.5"), published: published)

        // 0.5.6 stays (it's newer than 0.5.4); 0.5.1 is older and doesn't matter any more.
        #expect(after.skippedVersions == ["0.5.6", "0.5.5"])
    }

    @Test func goingUpClearsTheSkippedVersions() {
        let downgraded = ReleaseHistory.state(UpdateState(), afterInstalling: version("0.5.0"), over: version("0.5.5"), published: published)
        #expect(downgraded.skippedVersions == ["0.5.5", "0.5.4", "0.5.3"])

        let after = ReleaseHistory.state(downgraded, afterInstalling: version("0.5.4"), over: version("0.5.0"), published: published)

        #expect(after.skippedVersions.isEmpty)
    }

    @Test func reinstallingTheSameVersionChangesNothing() {
        let state = UpdateState(skippedVersions: ["0.5.5"])
        #expect(ReleaseHistory.state(state, afterInstalling: version("0.5.4"), over: version("0.5.4"), published: published) == state)
    }

    // MARK: - Saved state

    @Test func skippedVersionsAreNormalized() {
        var state = UpdateState(skippedVersions: ["v0.5.4", "0.5.10", "0.5.4", "garbage", "0.5.9"])
        #expect(state.skippedVersions == ["0.5.10", "0.5.9", "0.5.4"])
        state.skip(version("0.6.0"))
        state.skip(version("0.5.9"))
        #expect(state.skippedVersions == ["0.6.0", "0.5.10", "0.5.9", "0.5.4"])
    }

    @Test func singleSkippedVersionOfOlderVersionsIsRead() throws {
        let legacy = Data(#"{"formatVersion": 1, "lastCheckDate": 1800000000, "skippedVersion": "0.5.5"}"#.utf8)
        let state = try JSONDecoder().decode(UpdateState.self, from: legacy)
        #expect(state.skippedVersions == ["0.5.5"])
        #expect(state.lastCheckDate == Date(timeIntervalSince1970: 1_800_000_000))

        let both = Data(#"{"skippedVersions": ["0.5.4", 7], "skippedVersion": "0.5.5"}"#.utf8)
        // An unreadable list is dropped, the single version still counts.
        #expect(try JSONDecoder().decode(UpdateState.self, from: both).skippedVersions == ["0.5.5"])
        let merged = Data(#"{"skippedVersions": ["0.5.4"], "skippedVersion": "0.5.5"}"#.utf8)
        #expect(try JSONDecoder().decode(UpdateState.self, from: merged).skippedVersions == ["0.5.5", "0.5.4"])
    }

    @Test func newestSkippedVersionIsAlsoWrittenForOlderVersions() throws {
        let data = try JSONEncoder().encode(UpdateState(skippedVersions: ["0.5.4", "0.5.5"]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["skippedVersions"] as? [String] == ["0.5.5", "0.5.4"])
        // Versions up to 0.5.5 read only this key, and their checks only look at the latest release.
        #expect(object["skippedVersion"] as? String == "0.5.5")

        let empty = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(UpdateState())) as? [String: Any])
        #expect(empty["skippedVersions"] == nil)
        #expect(empty["skippedVersion"] == nil)
    }

    // MARK: - Fetching

    @Test func fetchesTheReleaseListFromGitHub() async throws {
        let url = StubURLProtocol.register(.init(body: Data(ReleaseListFixtures.mixed.utf8)), fileName: "releases")
        let feed = GitHubReleaseFeed(listURL: url, appVersion: "0.5.5", session: StubURLProtocol.makeSession())

        let releases = try await feed.releases()

        #expect(ReleaseHistory.installable(releases).count == 4)
        let request = try #require(StubURLProtocol.request(for: url))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CybokronLimitGuard/0.5.5")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test func releaseListErrorsAreReportedNotEmpty() async {
        func feed(_ response: StubURLProtocol.Response) -> GitHubReleaseFeed {
            GitHubReleaseFeed(listURL: StubURLProtocol.register(response, fileName: "releases"), appVersion: "0.5.5", session: StubURLProtocol.makeSession())
        }
        await #expect(throws: UpdateCheckError.rateLimited) { try await feed(.init(status: 403)).releases() }
        await #expect(throws: UpdateCheckError.rateLimited) { try await feed(.init(status: 429)).releases() }
        await #expect(throws: UpdateCheckError.httpStatus(500)) { try await feed(.init(status: 500)).releases() }
        await #expect(throws: UpdateCheckError.self) { try await feed(.init(body: Data("{}".utf8))).releases() }
        let offline = GitHubReleaseFeed(listURL: URL(string: "https://stub.test/unregistered")!, appVersion: "0.5.5", session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.self) { try await offline.releases() }
    }

    @Test func releaseListURLCanBePointedAtATestServer() {
        let variable = GitHubReleaseFeed.listURLOverrideVariable
        #expect(GitHubReleaseFeed.resolvedListURL(environment: [:]) == UpdateLinks.releasesAPI)
        #expect(UpdateLinks.releasesAPI.absoluteString == "https://api.github.com/repos/ercanatay/cybokron-limit-guard/releases?per_page=100")
        #expect(GitHubReleaseFeed.resolvedListURL(environment: [variable: "http://127.0.0.1:8765/releases.json"]).absoluteString
            == "http://127.0.0.1:8765/releases.json")
        #expect(GitHubReleaseFeed.resolvedListURL(environment: [variable: "file:///etc/hosts"]) == UpdateLinks.releasesAPI)
    }
}
