import Foundation
import Testing
@testable import LimitGuardCore

/// Answers requests from canned responses registered per URL, so no request leaves the process.
final class StubURLProtocol: URLProtocol {
    struct Response {
        var status = 200
        var body = Data()
        /// Extra response headers, e.g. an `ETag`.
        var headers: [String: String] = [:]
        /// The address the answer says it came from, as after a redirect; the request's own when `nil`.
        var finalURL: URL? = nil
    }

    private static let lock = NSLock()
    private static var responses: [URL: Response] = [:]
    private static var requests: [URL: URLRequest] = [:]

    /// Registers `response` under a fresh `https://stub.test/…` URL ending in `fileName`.
    static func register(_ response: Response, fileName: String = "latest") -> URL {
        let url = URL(string: "https://stub.test/\(UUID().uuidString)/\(fileName)")!
        lock.withLock { responses[url] = response }
        return url
    }

    static func request(for url: URL) -> URLRequest? {
        lock.withLock { requests[url] }
    }

    /// A session whose requests all go to this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = Self.lock.withLock({ () -> Response? in
            Self.requests[url] = request
            return Self.responses[url]
        }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let headers = response.headers.merging(["Content-Length": "\(response.body.count)"]) { own, _ in own }
        let http = HTTPURLResponse(url: response.finalURL ?? url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Release feed")
struct ReleaseFeedTests {
    private func feed(_ response: StubURLProtocol.Response) -> (GitHubReleaseFeed, URL) {
        let url = StubURLProtocol.register(response)
        return (GitHubReleaseFeed(url: url, appVersion: "0.5.0", session: StubURLProtocol.makeSession()), url)
    }

    @Test func fetchesAndParsesTheLatestRelease() async throws {
        let (feed, url) = feed(.init(body: ReleaseFixtures.data(ReleaseFixtures.v060WithDecoys)))

        let release = try await feed.latestRelease()

        #expect(release.version == SemanticVersion(major: 0, minor: 6, patch: 0))
        #expect(release.installerAsset?.name == "Cybokron-Limit-Guard-0.6.0-universal.dmg")
        let request = try #require(StubURLProtocol.request(for: url))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "CybokronLimitGuard/0.5.0")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.httpMethod == "GET")
    }

    @Test func httpErrorsBecomeUpdateErrors() async {
        await #expect(throws: UpdateCheckError.noPublishedRelease) { try await feed(.init(status: 404)).0.latestRelease() }
        await #expect(throws: UpdateCheckError.rateLimited) { try await feed(.init(status: 403)).0.latestRelease() }
        await #expect(throws: UpdateCheckError.httpStatus(502)) { try await feed(.init(status: 502)).0.latestRelease() }
        let unknown = GitHubReleaseFeed(url: URL(string: "https://stub.test/unregistered")!, appVersion: "0.5.0", session: StubURLProtocol.makeSession())
        await #expect(throws: UpdateCheckError.self) { try await unknown.latestRelease() }
    }

    @Test func feedURLCanBePointedAtATestServer() {
        let variable = GitHubReleaseFeed.urlOverrideVariable
        #expect(GitHubReleaseFeed.resolvedURL(environment: [:]) == UpdateLinks.latestReleaseAPI)
        #expect(UpdateLinks.latestReleaseAPI.absoluteString == "https://api.github.com/repos/ercanatay/cybokron-limit-guard/releases/latest")
        #expect(GitHubReleaseFeed.resolvedURL(environment: [variable: "http://127.0.0.1:8765/latest.json"]).absoluteString
            == "http://127.0.0.1:8765/latest.json")
        // Anything that isn't an http(s) URL is ignored.
        #expect(GitHubReleaseFeed.resolvedURL(environment: [variable: "file:///etc/hosts"]) == UpdateLinks.latestReleaseAPI)
        #expect(GitHubReleaseFeed.resolvedURL(environment: [variable: "not a url"]) == UpdateLinks.latestReleaseAPI)
    }
}
