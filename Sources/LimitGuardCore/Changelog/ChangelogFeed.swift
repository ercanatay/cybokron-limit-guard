import Foundation

/// What asking for the changelog's releases brought.
public enum ChangelogFetchResult: Sendable {
    /// The releases as the server lists them, with the answer's ETag for the next request.
    case releases([ReleaseInfo], etag: String?)
    /// Nothing changed since the copy whose ETag was sent (HTTP 304).
    case notModified
}

/// Fetches the releases behind Settings → Changelog.
public protocol ChangelogFetching: Sendable {
    /// With `etag` (the copy at hand's), an unchanged list comes back as `.notModified`.
    func releases(ifNoneMatch etag: String?) async throws -> ChangelogFetchResult
}

/// `ChangelogFetching` with GitHub's `GET /repos/{owner}/{repo}/releases?per_page=30`: the newest 30
/// releases, sent like the updater's requests (no token, only the app's version in the User-Agent).
/// The ETag of the last answer makes it a conditional request, which GitHub answers with an empty 304
/// when no release changed.
public struct GitHubChangelogFeed: ChangelogFetching {
    /// Environment variable that points the changelog at another release list JSON, e.g. a local test
    /// server: `CYBOKRON_CHANGELOG_FEED_URL=http://127.0.0.1:8765/releases.json`. Development builds
    /// only (`DevelopmentOverrides`).
    public static let urlOverrideVariable = "CYBOKRON_CHANGELOG_FEED_URL"

    /// `UpdateLinks.changelogReleasesAPI`, unless overrides are `enabled` (development builds) and
    /// `urlOverrideVariable` holds an https URL (or an http one to this Mac).
    public static func resolvedURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        overridesEnabled enabled: Bool = DevelopmentOverrides.areEnabled
    ) -> URL {
        GitHubAPI.overrideURL(urlOverrideVariable, in: environment, enabled: enabled) ?? UpdateLinks.changelogReleasesAPI
    }

    public let url: URL
    private let session: URLSession
    private let userAgent: String

    /// - Parameters:
    ///   - appVersion: Sent in the User-Agent header, which GitHub requires.
    ///   - session: Tests pass a session whose protocol classes answer without a network.
    public init(url: URL = GitHubChangelogFeed.resolvedURL(), appVersion: String, session: URLSession = .shared) {
        self.url = url
        self.session = session
        userAgent = "CybokronLimitGuard/\(appVersion)"
    }

    public func releases(ifNoneMatch etag: String?) async throws -> ChangelogFetchResult {
        switch try await GitHubAPI.get(url, userAgent: userAgent, session: session, ifNoneMatch: etag) {
        case .ok(let data, let etag):
            return .releases(try ReleaseInfo.decodeList(from: data), etag: etag)
        case .notModified:
            return .notModified
        }
    }
}
