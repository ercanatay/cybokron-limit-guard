import Foundation

/// A public profile shown as an icon button in the About window.
public struct SocialProfile: Identifiable, Equatable, Sendable {
    /// Stable key; also the key of the glyph in the app's icon table.
    public let id: String
    public let name: String
    public let url: URL

    public static let all: [SocialProfile] = [
        make("linkedin", "LinkedIn", "https://www.linkedin.com/in/ercanatay/"),
        make("x", "X", "https://twitter.com/ercanataytr"),
        make("instagram", "Instagram", "https://www.instagram.com/ercanatay"),
        make("youtube", "YouTube", "https://www.youtube.com/@ErcanAtay"),
        make("tiktok", "TikTok", "https://www.tiktok.com/@ercanatay"),
        make("threads", "Threads", "https://www.threads.net/@ercanatay"),
        make("pinterest", "Pinterest", "https://www.pinterest.com/ercanatay/"),
        make("steam", "Steam", "https://steamcommunity.com/id/cybokron/"),
        make("wordpress", "WordPress.org", "https://profiles.wordpress.org/cybokron/"),
        make("github", "GitHub", "https://github.com/ercanatay"),
        make("medium", "Medium", "https://ercanataycom.medium.com/"),
        make("facebook", "Facebook", "https://www.facebook.com/ercanatay"),
        make("vimeo", "Vimeo", "https://vimeo.com/ercanatay"),
        make("flickr", "Flickr", "https://www.flickr.com/photos/ercanatay/"),
        make("eksisozluk", "Ekşi Sözlük", "https://eksisozluk.com/biri/exert"),
        make("wikipedia", "Wikipedia", "https://tr.wikipedia.org/wiki/%C3%96zel:Katk%C4%B1lar/Cybokron"),
    ]

    private static func make(_ id: String, _ name: String, _ url: String) -> SocialProfile {
        SocialProfile(id: id, name: name, url: URL(string: url)!)
    }
}
