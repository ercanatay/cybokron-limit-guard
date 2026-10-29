import Foundation
import Testing
@testable import LimitGuardCore

@Suite("Release info and update decision")
struct ReleaseInfoTests {
    private func release(_ json: String) throws -> ReleaseInfo {
        try ReleaseInfo.decode(from: ReleaseFixtures.data(json))
    }

    private func version(_ text: String) throws -> SemanticVersion {
        try #require(SemanticVersion(text))
    }

    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, downloadURL: URL(string: "https://example.com/\(name)")!, size: 1)
    }

    // MARK: - Parsing

    @Test func parsesGitHubLatestRelease() throws {
        let info = try release(ReleaseFixtures.v050)

        #expect(info.tagName == "v0.5.0")
        #expect(info.version == SemanticVersion(major: 0, minor: 5, patch: 0))
        #expect(info.name == "v0.5.0")
        #expect(info.notes.hasPrefix("**Full Changelog**"))
        #expect(info.pageURL?.absoluteString == "https://github.com/ercanatay/cybokron-limit-guard/releases/tag/v0.5.0")
        #expect(info.publishedAt == ISO8601DateFormatter().date(from: "2026-10-17T13:24:51Z"))
        #expect(!info.isDraft)
        #expect(!info.isPrerelease)
        #expect(info.assets.count == 1)
        let dmg = try #require(info.installerAsset)
        #expect(dmg.name == "Cybokron-Limit-Guard-0.5.0-universal.dmg")
        #expect(dmg.size == 2_529_600)
        #expect(dmg.downloadURL.absoluteString == "https://github.com/ercanatay/cybokron-limit-guard/releases/download/v0.5.0/Cybokron-Limit-Guard-0.5.0-universal.dmg")
        #expect(dmg.sha256 == "3fd7bbe8309e72b987f705e34d9ebdd31f4e8c430de419abc2c2682457a89717")
    }

    @Test func missingFieldsFallBack() throws {
        let info = try release(ReleaseFixtures.v060WithoutDMG)

        #expect(info.version == SemanticVersion(major: 0, minor: 6, patch: 0))
        #expect(info.name == nil)
        #expect(info.notes.isEmpty)
        #expect(info.publishedAt == nil)
        #expect(info.installerAsset == nil)
    }

    @Test func rejectsWhatIsNotARelease() {
        #expect(throws: UpdateCheckError.self) { try release("<html>rate limited</html>") }
        #expect(throws: UpdateCheckError.self) { try release(#"{"message": "Not Found"}"#) }
        #expect(throws: UpdateCheckError.unsupportedTag("nightly")) { try release(#"{"tag_name": "nightly"}"#) }
    }

    // MARK: - Asset selection

    @Test func picksTheUniversalDMGAndSkipsDecoys() throws {
        let info = try release(ReleaseFixtures.v060WithDecoys)

        // The asset that is still uploading is dropped while parsing.
        #expect(info.assets.count == 4)
        let dmg = try #require(info.installerAsset)
        #expect(dmg.downloadURL.absoluteString == "https://example.com/Cybokron-Limit-Guard-0.6.0-universal.dmg")
        #expect(dmg.size == 2_600_000)
        #expect(info.notes == "## What's new\n- Faster popups\n- Bug fixes")
    }

    @Test func prefersTheDMGOfTheReleasedVersion() throws {
        let assets = [asset("Cybokron-Limit-Guard-0.5.0-universal.dmg"), asset("Cybokron-Limit-Guard-0.6.0-UNIVERSAL.DMG")]

        #expect(ReleaseAssetSelector.installerAsset(in: assets, version: try version("0.6.0"))?.name == "Cybokron-Limit-Guard-0.6.0-UNIVERSAL.DMG")
        #expect(ReleaseAssetSelector.installerAsset(in: assets)?.name == "Cybokron-Limit-Guard-0.5.0-universal.dmg")
        #expect(ReleaseAssetSelector.installerAsset(in: [asset("notes.txt"), asset("app-x86_64.dmg")]) == nil)
    }

    @Test func theVersionMustBeAWholeVersionNumberInTheName() throws {
        let decoys = [asset("Cybokron-Limit-Guard-0.5.10-universal.dmg"), asset("Cybokron-Limit-Guard-10.5.1-universal.dmg"), asset("Cybokron-Limit-Guard-0.5.1.2-universal.dmg")]
        let wanted = asset("Cybokron-Limit-Guard-0.5.1-universal.dmg")

        #expect(ReleaseAssetSelector.installerAsset(in: decoys + [wanted], version: try version("0.5.1")) == wanted)
        // None names it: the first universal DMG, as before.
        #expect(ReleaseAssetSelector.installerAsset(in: decoys, version: try version("0.5.1")) == decoys.first)

        for (name, matches) in [
            ("Cybokron-Limit-Guard-0.5.1-universal.dmg", true),
            ("Cybokron-Limit-Guard-v0.5.1-universal.dmg", true),
            ("Cybokron-Limit-Guard-0.5.10-universal.dmg", false),
            ("Cybokron-Limit-Guard-10.5.1-universal.dmg", false),
            ("Cybokron-Limit-Guard-0.5.1.2-universal.dmg", false),
            ("Cybokron-Limit-Guard-20.5.11-universal.dmg", false),
        ] {
            #expect(ReleaseAssetSelector.names(name, version: try version("0.5.1")) == matches, "\(name)")
        }
        #expect(ReleaseAssetSelector.names("Cybokron-Limit-Guard-0.7.0-beta.1-universal.dmg", version: try version("0.7.0-beta.1")))
        #expect(!ReleaseAssetSelector.names("Cybokron-Limit-Guard-0.7.0-beta.10-universal.dmg", version: try version("0.7.0-beta.1")))
        #expect(!ReleaseAssetSelector.names("Cybokron-Limit-Guard-0.7.0-universal.dmg", version: try version("0.7.0-beta.1")))
    }

    @Test func readsOnlySHA256Digests() {
        let url = URL(string: "https://example.com/a.dmg")!
        let hex = String(repeating: "ab", count: 32)
        #expect(ReleaseAsset(name: "a", downloadURL: url, size: 1, digest: "SHA256:\(hex.uppercased())").sha256 == hex)
        #expect(ReleaseAsset(name: "a", downloadURL: url, size: 1, digest: "sha512:\(hex)").sha256 == nil)
        #expect(ReleaseAsset(name: "a", downloadURL: url, size: 1, digest: "sha256:xyz").sha256 == nil)
        #expect(ReleaseAsset(name: "a", downloadURL: url, size: 1).sha256 == nil)
    }

    // MARK: - Decision

    @Test func sameOrOlderReleaseIsUpToDate() throws {
        let latest = try release(ReleaseFixtures.v050)

        #expect(UpdateDecision.evaluate(current: try version("0.5.0"), latest: latest)
            == .upToDate(current: try version("0.5.0"), latest: try version("0.5.0")))
        #expect(UpdateDecision.evaluate(current: try version("0.5.1"), latest: latest)
            == .upToDate(current: try version("0.5.1"), latest: try version("0.5.0")))
    }

    @Test func newerReleaseIsOfferedWithItsDMG() throws {
        let latest = try release(ReleaseFixtures.v060WithDecoys)

        guard case .available(let offered, let asset) = UpdateDecision.evaluate(current: try version("0.5.0"), latest: latest) else {
            Issue.record("Expected an available update")
            return
        }
        #expect(offered.version == SemanticVersion(major: 0, minor: 6, patch: 0))
        #expect(asset.name == "Cybokron-Limit-Guard-0.6.0-universal.dmg")
        #expect(asset.size == 2_600_000)

        let withoutDMG = try release(ReleaseFixtures.v060WithoutDMG)
        #expect(UpdateDecision.evaluate(current: try version("0.5.0"), latest: withoutDMG) == .availableWithoutInstaller(withoutDMG))
    }

    @Test func draftsAndPrereleasesAreHeldBack() throws {
        let draft = ReleaseInfo(tagName: "v0.7.0", version: try version("0.7.0"), isDraft: true, assets: [asset("x-universal.dmg")])
        let beta = ReleaseInfo(tagName: "v0.7.0-beta.1", version: try version("0.7.0-beta.1"), isPrerelease: true, assets: [asset("x-universal.dmg")])
        let final = ReleaseInfo(tagName: "v0.7.0", version: try version("0.7.0"), assets: [asset("x-universal.dmg")])

        #expect(UpdateDecision.evaluate(current: try version("0.5.0"), latest: draft) == .upToDate(current: try version("0.5.0"), latest: try version("0.7.0")))
        #expect(UpdateDecision.evaluate(current: try version("0.5.0"), latest: beta) == .upToDate(current: try version("0.5.0"), latest: try version("0.7.0-beta.1")))
        // A prerelease copy is offered newer prereleases and the final release.
        #expect(UpdateDecision.evaluate(current: try version("0.6.0-beta.1"), latest: beta) == .available(beta, asset: asset("x-universal.dmg")))
        #expect(UpdateDecision.evaluate(current: try version("0.7.0-beta.1"), latest: final) == .available(final, asset: asset("x-universal.dmg")))
    }

    // MARK: - Schedule

    @Test func automaticCheckIsDueEverySixHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateSchedule.checkInterval == 6 * 60 * 60)
        #expect(UpdateSchedule.isCheckDue(lastCheck: nil, now: now))
        #expect(!UpdateSchedule.isCheckDue(lastCheck: now.addingTimeInterval(-60), now: now))
        #expect(!UpdateSchedule.isCheckDue(lastCheck: now.addingTimeInterval(-UpdateSchedule.checkInterval + 1), now: now))
        #expect(UpdateSchedule.isCheckDue(lastCheck: now.addingTimeInterval(-UpdateSchedule.checkInterval), now: now))
        // The clock was set back.
        #expect(UpdateSchedule.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
