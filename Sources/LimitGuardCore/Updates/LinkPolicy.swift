import Foundation

/// Which addresses from what GitHub (or a test server) sends the app follows: links in release
/// notes, a release's page, and the feed addresses the environment may override. Release notes are
/// written by whoever publishes a release, so their links mustn't open files, scripts, other apps —
/// or this app's own `cybokronlimitguard:` commands.
public enum LinkPolicy {
    /// Whether a link in release notes, and in the windows that show them, may be opened: an
    /// `https` address with a host and no user name or password in it, or a `mailto:` address.
    /// Everything else — `file:`, `javascript:`, plain `http:`, `cybokronlimitguard:` and other
    /// apps' schemes — isn't. A user name dresses one host up as another
    /// (`https://github.com%2F@evil.example` goes to evil.example), so such links show as text.
    public static func isClickable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return !(url.host ?? "").isEmpty && !hasUserInfo(url)
        case "mailto":
            return true
        default:
            return false
        }
    }

    /// Whether `url` has a user name or password (`https://user:password@host`), even an empty one.
    public static func hasUserInfo(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        return components.percentEncodedUser != nil || components.percentEncodedPassword != nil
    }

    /// `text` with every link `isClickable` refuses turned into plain text (the words stay).
    public static func removingUnclickableLinks(from text: AttributedString) -> AttributedString {
        var result = text
        let refused = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link else { return nil }
            return isClickable(link) ? nil : run.range
        }
        for range in refused {
            result[range].link = nil
        }
        return result
    }

    /// A release's page on the web: an `https` address with a host and no user name or password,
    /// otherwise `nil`.
    public static func webPageURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https",
              !(url.host ?? "").isEmpty, !hasUserInfo(url)
        else { return nil }
        return url
    }

    /// The hosts GitHub's API answers may come from, also after redirects.
    public static let gitHubAPIHosts: Set<String> = ["api.github.com", "github.com"]

    /// Whether an API answer that arrived from `finalURL` (after any redirects) for a request to
    /// `requestURL` may be used: over `https` from one of `gitHubAPIHosts`, or from the very host
    /// and scheme asked (a development build's local feed override, `DevelopmentOverrides`).
    public static func isAllowedAPIAnswer(from finalURL: URL, for requestURL: URL) -> Bool {
        guard !hasUserInfo(finalURL), let host = finalURL.host?.lowercased(), !host.isEmpty else { return false }
        if finalURL.scheme?.lowercased() == "https", gitHubAPIHosts.contains(host) {
            return true
        }
        return host == requestURL.host?.lowercased()
            && finalURL.scheme?.lowercased() == requestURL.scheme?.lowercased()
            && finalURL.port == requestURL.port
            && isSecureOrLocal(finalURL)
    }

    /// HTTPS anywhere; plain HTTP only to this Mac (a local test server). For the update feeds and
    /// the update's download.
    public static func isSecureOrLocal(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return !(url.host ?? "").isEmpty
        case "http":
            return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        default:
            return false
        }
    }
}
