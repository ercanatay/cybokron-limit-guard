import Foundation

/// A file attached to a GitHub release.
public struct ReleaseAsset: Hashable, Sendable {
    public let name: String
    public let downloadURL: URL
    /// Size in bytes as GitHub reports it.
    public let size: Int
    /// GitHub's checksum of the file, e.g. `sha256:3fd7…`; older releases have none.
    public let digest: String?

    public init(name: String, downloadURL: URL, size: Int, digest: String? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.digest = digest
    }

    /// The lowercase hex SHA-256 from `digest`, `nil` when there's none or it's another algorithm.
    public var sha256: String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

/// A published release of the app, from GitHub's `GET /repos/{owner}/{repo}/releases/latest`.
public struct ReleaseInfo: Hashable, Sendable {
    /// The git tag, e.g. `v0.5.1`.
    public let tagName: String
    /// The version the tag names.
    public let version: SemanticVersion
    /// The release title, `nil` when it has none.
    public let name: String?
    /// The release notes (Markdown); empty when there are none.
    public let notes: String
    /// The release's page on GitHub; only an `https` address is read (`LinkPolicy.webPageURL`).
    public let pageURL: URL?
    public let publishedAt: Date?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [ReleaseAsset]

    public init(
        tagName: String,
        version: SemanticVersion,
        name: String? = nil,
        notes: String = "",
        pageURL: URL? = nil,
        publishedAt: Date? = nil,
        isDraft: Bool = false,
        isPrerelease: Bool = false,
        assets: [ReleaseAsset] = []
    ) {
        self.tagName = tagName
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.assets = assets
    }

    /// The disk image the updater installs from; see `ReleaseAssetSelector`.
    public var installerAsset: ReleaseAsset? {
        ReleaseAssetSelector.installerAsset(in: assets, version: version)
    }

    /// Parses GitHub's release JSON. Assets without a usable download URL are skipped; a release
    /// whose tag isn't a version number is an error.
    public static func decode(from data: Data) throws -> ReleaseInfo {
        let raw: RawRelease
        do {
            raw = try makeDecoder().decode(RawRelease.self, from: data)
        } catch {
            throw UpdateCheckError.malformedRelease(String(describing: error))
        }
        return try ReleaseInfo(raw)
    }

    /// Parses GitHub's list of releases (`GET /repos/{owner}/{repo}/releases`), in the order given.
    /// Entries that can't be read or whose tag isn't a version number are left out; an answer that
    /// isn't a list is an error.
    public static func decodeList(from data: Data) throws -> [ReleaseInfo] {
        let entries: [Lenient<RawRelease>]
        do {
            entries = try makeDecoder().decode([Lenient<RawRelease>].self, from: data)
        } catch {
            throw UpdateCheckError.malformedRelease(String(describing: error))
        }
        return entries.compactMap { entry in entry.value.flatMap { try? ReleaseInfo($0) } }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private init(_ raw: RawRelease) throws {
        guard let version = SemanticVersion(raw.tagName) else {
            throw UpdateCheckError.unsupportedTag(raw.tagName)
        }
        let assets = (raw.assets ?? []).compactMap { asset -> ReleaseAsset? in
            guard asset.state == nil || asset.state == "uploaded",
                  let name = asset.name, !name.isEmpty,
                  let link = asset.browserDownloadURL, let url = URL(string: link), url.scheme != nil
            else { return nil }
            return ReleaseAsset(name: name, downloadURL: url, size: asset.size ?? 0, digest: asset.digest)
        }
        self.init(
            tagName: raw.tagName,
            version: version,
            name: raw.name.flatMap { $0.isEmpty ? nil : $0 },
            notes: raw.body ?? "",
            pageURL: LinkPolicy.webPageURL(raw.htmlURL),
            publishedAt: raw.publishedAt,
            isDraft: raw.draft ?? false,
            isPrerelease: raw.prerelease ?? false,
            assets: assets
        )
    }
}

/// A list element that decodes to `nil` instead of failing the whole list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Picks the release asset to install: the universal disk image built by `scripts/make-dmg.sh`
/// (`Cybokron-Limit-Guard-<version>-universal.dmg`). Other files — zips, checksums, per-architecture
/// builds — are never chosen.
public enum ReleaseAssetSelector {
    public static let requiredSuffix = "universal.dmg"

    /// The first asset whose name ends in `universal.dmg` (any case), preferring one that also
    /// names `version` (`names(_:version:)`). `nil` when the release has none.
    public static func installerAsset(in assets: [ReleaseAsset], version: SemanticVersion? = nil) -> ReleaseAsset? {
        let candidates = assets.filter { $0.name.lowercased().hasSuffix(requiredSuffix) }
        if let version, let named = candidates.first(where: { names($0.name, version: version) }) {
            return named
        }
        return candidates.first
    }

    /// Whether the file name holds `version` as a whole version number: `0.5.1` is in
    /// `…-0.5.1-universal.dmg` but not in `…-0.5.10-…` or `…-10.5.1-…`, and a prerelease such as
    /// `0.7.0-beta.1` needs its identifiers too (`…-0.7.0-beta.1-…`, not `…-0.7.0-beta.10-…`).
    static func names(_ fileName: String, version: SemanticVersion) -> Bool {
        var text = "\(version.major).\(version.minor).\(version.patch)"
        if version.isPrerelease {
            text += "-" + version.prerelease.joined(separator: ".")
        }
        // Not glued to more digits or version parts on either side.
        let pattern = #"(?<![0-9A-Za-z.])v?"# + NSRegularExpression.escapedPattern(for: text) + #"(?![0-9A-Za-z]|\.[0-9])"#
        return fileName.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// The parts of GitHub's release object the updater reads; everything is optional except the tag.
private struct RawRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String?
    let publishedAt: Date?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [RawAsset]?

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        body = try? container.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try? container.decodeIfPresent(String.self, forKey: .htmlURL)
        publishedAt = try? container.decodeIfPresent(Date.self, forKey: .publishedAt)
        draft = try? container.decodeIfPresent(Bool.self, forKey: .draft)
        prerelease = try? container.decodeIfPresent(Bool.self, forKey: .prerelease)
        assets = try? container.decodeIfPresent([RawAsset].self, forKey: .assets)
    }
}

private struct RawAsset: Decodable {
    let name: String?
    let browserDownloadURL: String?
    let size: Int?
    let state: String?
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name, size, state, digest
        case browserDownloadURL = "browser_download_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        browserDownloadURL = try? container.decodeIfPresent(String.self, forKey: .browserDownloadURL)
        size = try? container.decodeIfPresent(Int.self, forKey: .size)
        state = try? container.decodeIfPresent(String.self, forKey: .state)
        digest = try? container.decodeIfPresent(String.self, forKey: .digest)
    }
}
