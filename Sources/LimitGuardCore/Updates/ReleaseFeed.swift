import Foundation

/// Fetches the latest published release.
public protocol ReleaseFetching: Sendable {
    func latestRelease() async throws -> ReleaseInfo
}

/// Fetches every published release, for "Other Versions…".
public protocol ReleaseListFetching: Sendable {
    /// The releases as the server lists them (drafts and prereleases included, if it sends any);
    /// `ReleaseHistory.installable` picks the ones to offer.
    func releases() async throws -> [ReleaseInfo]
}

/// `ReleaseFetching` with GitHub's REST API (`GET /repos/{owner}/{repo}/releases/latest`), which
/// returns the newest release that is neither a draft nor a prerelease, and `ReleaseListFetching`
/// with `GET /repos/{owner}/{repo}/releases` (the newest 100, more than the project has). No token is
/// sent; GitHub allows 60 such requests an hour per IP address, far more than the checks need. These,
/// and Settings → Changelog's list of releases (`GitHubChangelogFeed`), are the only requests the app
/// makes besides downloading a release's disk image.
public struct GitHubReleaseFeed: ReleaseFetching, ReleaseListFetching {
    /// Environment variable that points the updater at another release JSON, e.g. a local test
    /// server: `CYBOKRON_UPDATE_FEED_URL=http://127.0.0.1:8765/latest.json`. Development builds
    /// only (`DevelopmentOverrides`).
    public static let urlOverrideVariable = "CYBOKRON_UPDATE_FEED_URL"

    /// `UpdateLinks.latestReleaseAPI`, unless overrides are `enabled` (development builds) and
    /// `urlOverrideVariable` holds an https URL (or an http one to this Mac).
    public static func resolvedURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        overridesEnabled enabled: Bool = DevelopmentOverrides.areEnabled
    ) -> URL {
        GitHubAPI.overrideURL(urlOverrideVariable, in: environment, enabled: enabled) ?? UpdateLinks.latestReleaseAPI
    }

    /// Environment variable that points "Other Versions…" at another release list JSON:
    /// `CYBOKRON_RELEASES_FEED_URL=http://127.0.0.1:8765/releases.json`. Development builds only.
    public static let listURLOverrideVariable = "CYBOKRON_RELEASES_FEED_URL"

    /// `UpdateLinks.releasesAPI`, unless overrides are `enabled` (development builds) and
    /// `listURLOverrideVariable` holds an https URL (or an http one to this Mac).
    public static func resolvedListURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        overridesEnabled enabled: Bool = DevelopmentOverrides.areEnabled
    ) -> URL {
        GitHubAPI.overrideURL(listURLOverrideVariable, in: environment, enabled: enabled) ?? UpdateLinks.releasesAPI
    }

    public let url: URL
    public let listURL: URL
    private let session: URLSession
    private let userAgent: String

    /// - Parameters:
    ///   - appVersion: Sent in the User-Agent header, which GitHub requires.
    ///   - session: Tests pass a session whose protocol classes answer without a network.
    public init(
        url: URL = GitHubReleaseFeed.resolvedURL(),
        listURL: URL = GitHubReleaseFeed.resolvedListURL(),
        appVersion: String,
        session: URLSession = .shared
    ) {
        self.url = url
        self.listURL = listURL
        self.session = session
        userAgent = "CybokronLimitGuard/\(appVersion)"
    }

    public func latestRelease() async throws -> ReleaseInfo {
        try ReleaseInfo.decode(from: await fetch(url))
    }

    public func releases() async throws -> [ReleaseInfo] {
        try ReleaseInfo.decodeList(from: await fetch(listURL))
    }

    /// GETs `url` from GitHub's API; HTTP errors become `UpdateCheckError`s.
    private func fetch(_ url: URL) async throws -> Data {
        switch try await GitHubAPI.get(url, userAgent: userAgent, session: session) {
        case .ok(let data, _):
            return data
        case .notModified:
            // Only an answer to a request with an ETag; none is sent here.
            throw UpdateCheckError.httpStatus(304)
        }
    }
}

/// GET requests to GitHub's REST API, shared by the updater and Settings → Changelog: GitHub's JSON
/// media type and API version, a User-Agent (which GitHub requires) and no token.
enum GitHubAPI {
    /// What a GET brought.
    enum Answer {
        /// HTTP 200, with the answer's ETag (for a later conditional request).
        case ok(Data, etag: String?)
        /// HTTP 304: nothing changed since the copy whose ETag was sent.
        case notModified
    }

    /// GETs `url`. With `etag` it's a conditional request (`If-None-Match`), which GitHub answers
    /// with 304 and no body when nothing changed. Other HTTP errors become `UpdateCheckError`s.
    static func get(_ url: URL, userAgent: String, session: URLSession, ifNoneMatch etag: String? = nil) async throws -> Answer {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw UpdateCheckError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.network(Localization.string("core.update.check.notHTTP", "The answer wasn't HTTP."))
        }
        // Redirects are followed; the answer must still come from GitHub over HTTPS (or from the
        // host a development override asked).
        if let finalURL = http.url, !LinkPolicy.isAllowedAPIAnswer(from: finalURL, for: url) {
            throw UpdateCheckError.network("redirected to \(finalURL.host ?? finalURL.absoluteString)")
        }
        switch http.statusCode {
        case 200:
            return .ok(data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304 where etag != nil:
            return .notModified
        case 404:
            throw UpdateCheckError.noPublishedRelease
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
    }

    /// The URL in the environment variable `variable` (to point a request at a local test server),
    /// `nil` when it holds none or overrides aren't `enabled` (release builds,
    /// `DevelopmentOverrides`): it must be `https`, or plain `http` to this Mac only
    /// (`LinkPolicy.isSecureOrLocal`), so release information is never read unencrypted from
    /// another machine.
    static func overrideURL(_ variable: String, in environment: [String: String], enabled: Bool = DevelopmentOverrides.areEnabled) -> URL? {
        guard let value = DevelopmentOverrides.value(variable, in: environment, enabled: enabled)?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: value), LinkPolicy.isSecureOrLocal(url)
        else { return nil }
        return url
    }
}
