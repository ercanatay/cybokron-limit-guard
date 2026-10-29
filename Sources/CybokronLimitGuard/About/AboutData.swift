import Foundation

/// Static content of the About window: every external URL lives here.
enum AboutData {
    struct Donation: Identifiable {
        let title: String
        let symbol: String
        let url: URL
        var id: String { title }
    }

    struct Book: Identifiable {
        let title: String
        let turkishTitle: String
        let englishURL: URL
        let turkishURL: URL
        let coverURL: URL
        var id: String { title }
        var titleLine: String { "\(title) · \(turkishTitle)" }
    }

    struct Link: Identifiable {
        let title: String
        let subtitle: String
        let symbol: String
        let url: URL
        var id: String { title }
    }

    static let websiteURL = url("https://cybokron.com")
    static let issuesURL = url("https://github.com/ercanatay/cybokron-limit-guard/issues")

    static let donations = [
        Donation(title: "Buy Me a Coffee", symbol: "cup.and.saucer.fill", url: url("https://buymeacoffee.com/ercanatay")),
        Donation(title: "Ko-fi", symbol: "heart.fill", url: url("https://ko-fi.com/ercanatay")),
        Donation(title: "GitHub Sponsors", symbol: "star.circle.fill", url: url("https://github.com/sponsors/ercanatay")),
    ]

    static let books = [
        Book(title: "HOPE", turkishTitle: "UMUT",
             englishURL: url("https://www.ercanatay.com/en/hope/"),
             turkishURL: url("https://www.ercanatay.com/umut/"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Cover1-LQ-scaled.jpeg")),
        Book(title: "YELLOW", turkishTitle: "SARI",
             englishURL: url("https://www.ercanatay.com/en/yellow/"),
             turkishURL: url("https://www.ercanatay.com/sari/"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Cover-scaled.jpg")),
        Book(title: "Digital Marketing in Healthcare", turkishTitle: "Sağlık Sektöründe Dijital Pazarlama",
             englishURL: url("https://www.ercanatay.com/en/digital-marketing-in-healthcare/"),
             turkishURL: url("https://www.ercanatay.com/saglik"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/English-Book-2.png")),
        Book(title: "International SEO", turkishTitle: "Uluslararası SEO",
             englishURL: url("https://www.ercanatay.com/en/international-seo/"),
             turkishURL: url("https://www.ercanatay.com/uluslararasi-seo/"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Book-2-EN.png")),
    ]

    static let projects = [
        Link(title: "cybokron-limit-guard", subtitle: L10n.About.Project.limitGuard,
             symbol: "gauge.with.dots.needle.67percent", url: url("https://github.com/ercanatay/cybokron-limit-guard")),
        Link(title: "cybokron-dock-groups", subtitle: L10n.About.Project.dockGroups,
             symbol: "square.stack.3d.up.fill", url: url("https://github.com/ercanatay/cybokron-dock-groups")),
        Link(title: "intel-computer-use", subtitle: L10n.About.Project.intelComputerUse,
             symbol: "desktopcomputer", url: url("https://github.com/ercanatay/intel-computer-use")),
        Link(title: "cybokron-exchange-rate-and-portfolio-tracking", subtitle: L10n.About.Project.exchangeRate,
             symbol: "chart.line.uptrend.xyaxis", url: url("https://github.com/ercanatay/cybokron-exchange-rate-and-portfolio-tracking")),
        Link(title: "cybokron-backlink-checker", subtitle: L10n.About.Project.backlinkChecker,
             symbol: "link", url: url("https://github.com/ercanatay/cybokron-backlink-checker")),
        Link(title: "cybokron-consent-manager-translations-yootheme", subtitle: L10n.About.Project.consentManager,
             symbol: "globe", url: url("https://github.com/ercanatay/cybokron-consent-manager-translations-yootheme")),
        Link(title: "cybokron-antigravity-manager-updater", subtitle: L10n.About.Project.antigravityUpdater,
             symbol: "arrow.triangle.2.circlepath", url: url("https://github.com/ercanatay/cybokron-antigravity-manager-updater")),
        Link(title: "cybokron-advanced-widget-visibility", subtitle: L10n.About.Project.widgetVisibility,
             symbol: "eye", url: url("https://github.com/ercanatay/cybokron-advanced-widget-visibility")),
        Link(title: "cybokron-forbidden-content-checker", subtitle: L10n.About.Project.forbiddenContent,
             symbol: "exclamationmark.shield", url: url("https://github.com/ercanatay/cybokron-forbidden-content-checker")),
    ]

    static let blogs = [
        Link(title: "Medium (Türkçe)", subtitle: "ercanatay.medium.com", symbol: "text.book.closed",
             url: url("https://ercanatay.medium.com")),
        Link(title: "Medium (English)", subtitle: "ercanataycom.medium.com", symbol: "text.book.closed",
             url: url("https://ercanataycom.medium.com")),
    ]

    private static func url(_ string: String) -> URL { URL(string: string)! }
}
