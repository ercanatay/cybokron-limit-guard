import Foundation

/// A published release as Settings → Changelog lists it, and as `changelog-cache.json` keeps it.
public struct ChangelogEntry: Hashable, Sendable, Identifiable {
    /// The git tag, e.g. `v0.6.0`.
    public let tagName: String
    /// The version the tag names.
    public let version: SemanticVersion
    /// The release title, `nil` when it has none.
    public let name: String?
    /// The release notes (Markdown); empty when there are none.
    public let notes: String
    public let publishedAt: Date?
    public let isPrerelease: Bool
    /// The release's page on GitHub.
    public let pageURL: URL?

    public var id: String { tagName }

    public init(
        tagName: String,
        version: SemanticVersion,
        name: String? = nil,
        notes: String = "",
        publishedAt: Date? = nil,
        isPrerelease: Bool = false,
        pageURL: URL? = nil
    ) {
        self.tagName = tagName
        self.version = version
        self.name = name
        self.notes = notes
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.pageURL = pageURL
    }

    public init(_ release: ReleaseInfo) {
        self.init(
            tagName: release.tagName,
            version: release.version,
            name: release.name,
            notes: release.notes,
            publishedAt: release.publishedAt,
            isPrerelease: release.isPrerelease || release.version.isPrerelease,
            pageURL: release.pageURL
        )
    }

    /// The release's title when it says more than its version: GitHub names a release after its tag
    /// unless it's given a title, and "v0.6.0" over v0.6.0 says nothing new.
    public var title: String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name != tagName, SemanticVersion(name) != version
        else { return nil }
        return name
    }

    /// The notes cut into blocks to show; empty when the release has none, and the pane says so.
    public var noteBlocks: [ReleaseNotesBlock] {
        ReleaseNotesMarkdown.blocks(notes)
    }

    public var hasNotes: Bool {
        !noteBlocks.isEmpty
    }
}

extension ChangelogEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case tagName, name, notes, publishedAt, isPrerelease, pageURL
    }

    /// Only the tag is required (and must name a version); the rest falls back. A page address
    /// that isn't `https` is dropped (`LinkPolicy.webPageURL`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tagName = try container.decode(String.self, forKey: .tagName)
        guard let version = SemanticVersion(tagName) else {
            throw DecodingError.dataCorruptedError(forKey: .tagName, in: container, debugDescription: "“\(tagName)” isn't a version")
        }
        self.init(
            tagName: tagName,
            version: version,
            name: container.decodeLeniently(String.self, forKey: .name),
            notes: container.decodeLeniently(String.self, forKey: .notes) ?? "",
            publishedAt: container.decodeLeniently(Double.self, forKey: .publishedAt).map(Date.init(timeIntervalSince1970:)),
            isPrerelease: container.decodeLeniently(Bool.self, forKey: .isPrerelease) ?? version.isPrerelease,
            pageURL: LinkPolicy.webPageURL(container.decodeLeniently(String.self, forKey: .pageURL))
        )
    }

    /// Dates as seconds since 1970, like `update-state.json`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagName, forKey: .tagName)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(publishedAt?.timeIntervalSince1970, forKey: .publishedAt)
        try container.encode(isPrerelease, forKey: .isPrerelease)
        try container.encodeIfPresent(pageURL?.absoluteString, forKey: .pageURL)
    }
}

/// The marks next to a release's version in Settings → Changelog.
public struct ChangelogBadges: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The newest release that isn't a prerelease, as GitHub's "Latest".
    public static let latest = ChangelogBadges(rawValue: 1 << 0)
    /// The version that runs.
    public static let installed = ChangelogBadges(rawValue: 1 << 1)
    public static let prerelease = ChangelogBadges(rawValue: 1 << 2)
}

/// The release list Settings → Changelog shows until GitHub sends a newer one, in
/// `changelog-cache.json` next to `update-state.json`.
public struct ChangelogCache: Equatable, Sendable {
    /// When GitHub last sent the list or confirmed it hasn't changed (HTTP 304).
    public var fetchedAt: Date
    /// GitHub's ETag for the list, sent back to ask whether it changed.
    public var etag: String?
    /// Newest first; see `ChangelogService.entries(from:)`.
    public var entries: [ChangelogEntry]

    public init(fetchedAt: Date, etag: String? = nil, entries: [ChangelogEntry]) {
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.entries = entries
    }
}

extension ChangelogCache: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, fetchedAt, etag, entries
    }

    /// Entries that can't be read are left out; a missing date counts as long ago, so the list is
    /// refreshed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = Date(timeIntervalSince1970: container.decodeLeniently(Double.self, forKey: .fetchedAt) ?? 0)
        etag = container.decodeLeniently(String.self, forKey: .etag)
        let list = container.decodeLeniently([Lenient<ChangelogEntry>].self, forKey: .entries) ?? []
        entries = list.compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .formatVersion)
        try container.encode(fetchedAt.timeIntervalSince1970, forKey: .fetchedAt)
        try container.encodeIfPresent(etag, forKey: .etag)
        try container.encode(entries, forKey: .entries)
    }
}

/// Reads and writes the changelog cache.
public protocol ChangelogCachePersisting: Sendable {
    /// The saved cache, `nil` when there's none (or it can't be read).
    func load() -> ChangelogCache?
    func save(_ cache: ChangelogCache) throws
}

/// Stores the `ChangelogCache` as JSON, by default in
/// `~/Library/Application Support/Cybokron Limit Guard/changelog-cache.json`.
public struct JSONFileChangelogCachePersistence: ChangelogCachePersisting {
    public static var defaultFileURL: URL { defaultFileURL(in: DataDirectory.url) }

    static func defaultFileURL(in directory: URL) -> URL {
        directory.appending(path: "changelog-cache.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileChangelogCachePersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// A missing or unreadable file means no cache: it only holds a copy of what GitHub lists.
    public func load() -> ChangelogCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ChangelogCache.self, from: data)
    }

    public func save(_ cache: ChangelogCache) throws {
        try JSONFileSupport.write(cache, to: fileURL)
    }
}
