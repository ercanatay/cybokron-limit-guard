import Foundation

/// What the updater remembers between launches, in `update-state.json` in the data folder. Kept
/// apart from `settings.json` because it changes with every check, not only with the user's choices.
public struct UpdateState: Equatable, Sendable {
    /// When the latest check finished, successfully or not.
    public var lastCheckDate: Date?
    /// Whether the app checks for updates by itself, shortly after launch and every six hours.
    public var automaticallyChecks: Bool
    /// Versions automatic checks don't offer: one the user chose to skip, or the newer releases
    /// skipped when an older version was installed from "Other Versions…". Newest first, each once,
    /// without a `v` (see `normalizedSkippedVersions`).
    public var skippedVersions: [String] {
        didSet { skippedVersions = Self.normalizedSkippedVersions(skippedVersions) }
    }

    public init(lastCheckDate: Date? = nil, automaticallyChecks: Bool = true, skippedVersions: [String] = []) {
        self.lastCheckDate = lastCheckDate
        self.automaticallyChecks = automaticallyChecks
        self.skippedVersions = Self.normalizedSkippedVersions(skippedVersions)
    }

    /// Whether automatic checks keep quiet about `version`.
    public func isSkipped(_ version: SemanticVersion) -> Bool {
        skippedVersions.contains { SemanticVersion($0) == version }
    }

    /// Adds `version` to the skipped versions.
    public mutating func skip(_ version: SemanticVersion) {
        skippedVersions.append(version.description)
    }

    /// Version numbers only (entries that aren't one are dropped), written without a `v`, each once,
    /// newest first.
    public static func normalizedSkippedVersions(_ versions: [String]) -> [String] {
        var seen: Set<SemanticVersion> = []
        return versions
            .compactMap(SemanticVersion.init)
            .filter { seen.insert($0).inserted }
            .sorted(by: >)
            .map(\.description)
    }
}

extension UpdateState: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, lastCheckDate, automaticallyChecks, skippedVersions, skippedVersion
    }

    /// Every field is optional; unreadable values are dropped. `skippedVersion` (a single version) is
    /// what versions up to 0.5.5 write; it's merged into the list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheckDate = container.decodeLeniently(Double.self, forKey: .lastCheckDate).map(Date.init(timeIntervalSince1970:))
        automaticallyChecks = container.decodeLeniently(Bool.self, forKey: .automaticallyChecks) ?? true
        let list = container.decodeLeniently([String].self, forKey: .skippedVersions) ?? []
        let single = container.decodeLeniently(String.self, forKey: .skippedVersion)
        skippedVersions = Self.normalizedSkippedVersions(list + [single].compactMap { $0 })
    }

    /// Dates as seconds since 1970, like the usage statistics. The newest skipped version is also
    /// written as `skippedVersion`, the only key older versions read: after going back to one, its
    /// automatic checks (which only look at the latest release) keep quiet about the newest release.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .formatVersion)
        try container.encodeIfPresent(lastCheckDate?.timeIntervalSince1970, forKey: .lastCheckDate)
        if !automaticallyChecks {
            try container.encode(false, forKey: .automaticallyChecks)
        }
        if !skippedVersions.isEmpty {
            try container.encode(skippedVersions, forKey: .skippedVersions)
            try container.encode(skippedVersions[0], forKey: .skippedVersion)
        }
    }
}

/// Stores the `UpdateState` as JSON, by default in
/// `~/Library/Application Support/Cybokron Limit Guard/update-state.json`.
public struct JSONFileUpdateStatePersistence: Sendable {
    public static var defaultFileURL: URL { defaultFileURL(in: DataDirectory.url) }

    static func defaultFileURL(in directory: URL) -> URL {
        directory.appending(path: "update-state.json", directoryHint: .notDirectory)
    }

    public let fileURL: URL

    public init(fileURL: URL = JSONFileUpdateStatePersistence.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// The saved state; a missing or unreadable file means a fresh state (the file only holds
    /// conveniences, nothing worth keeping aside).
    public func load() -> UpdateState {
        guard let data = try? Data(contentsOf: fileURL) else { return UpdateState() }
        return (try? JSONDecoder().decode(UpdateState.self, from: data)) ?? UpdateState()
    }

    public func save(_ state: UpdateState) throws {
        try JSONFileSupport.write(state, to: fileURL)
    }
}
