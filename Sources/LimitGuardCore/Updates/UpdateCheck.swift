import Foundation

/// Why looking for an update failed.
public enum UpdateCheckError: LocalizedError, Equatable, Sendable {
    /// The server answered with something that isn't a release.
    case malformedRelease(String)
    /// The latest release's tag isn't a version number.
    case unsupportedTag(String)
    /// The repository has no published release yet (HTTP 404).
    case noPublishedRelease
    /// GitHub's limit for unauthenticated requests was reached (HTTP 403 or 429).
    case rateLimited
    /// Any other HTTP status.
    case httpStatus(Int)
    /// The request didn't get an HTTP answer (offline, timeout, …).
    case network(String)
    /// The app's own version couldn't be read.
    case unknownCurrentVersion

    public var errorDescription: String? {
        switch self {
        case .malformedRelease:
            return Localization.string("core.update.check.malformed", "The release information from GitHub couldn't be read.")
        case .unsupportedTag(let tag):
            return Localization.format("core.update.check.unsupportedTag", "The latest release (“%@”) isn't tagged with a version number.", tag)
        case .noPublishedRelease:
            return Localization.string("core.update.check.noRelease", "No release has been published yet.")
        case .rateLimited:
            return Localization.string("core.update.check.rateLimited", "GitHub is limiting requests right now. Try again in an hour.")
        case .httpStatus(let status):
            return Localization.format("core.update.check.httpStatus", "GitHub answered with HTTP status %ld.", status)
        case .network(let reason):
            return Localization.format("core.update.check.network", "GitHub couldn't be reached: %@", reason)
        case .unknownCurrentVersion:
            return Localization.string("core.update.check.noVersion", "This copy of the app has no version number, so it can't be compared.")
        }
    }
}

/// The outcome of comparing the running app with the latest release.
public enum UpdateAvailability: Equatable, Sendable {
    /// Nothing newer: the latest release is this version or older (or isn't meant for this copy).
    case upToDate(current: SemanticVersion, latest: SemanticVersion)
    /// A newer release with a disk image to install from.
    case available(ReleaseInfo, asset: ReleaseAsset)
    /// A newer release without a universal disk image; it can only be downloaded by hand.
    case availableWithoutInstaller(ReleaseInfo)
}

public enum UpdateDecision {
    /// Compares `current` with `latest`. Drafts are never offered, and prereleases only to copies
    /// that run a prerelease themselves.
    public static func evaluate(current: SemanticVersion, latest: ReleaseInfo) -> UpdateAvailability {
        let offered = !latest.isDraft && (!latest.isPrerelease || current.isPrerelease)
        guard offered, latest.version > current else {
            return .upToDate(current: current, latest: latest.version)
        }
        if let asset = latest.installerAsset {
            return .available(latest, asset: asset)
        }
        return .availableWithoutInstaller(latest)
    }
}

/// When the automatic update checks run: at launch and every six hours after the last check.
public enum UpdateSchedule {
    public static let checkInterval: TimeInterval = 6 * 60 * 60
    /// How often the app looks whether a check is due. Timers don't run while the Mac sleeps, so a
    /// short tick (and a look after waking) keeps the six hours close to wall-clock time.
    public static let tickInterval: TimeInterval = 15 * 60

    /// Whether an automatic check is due: never checked, the interval has passed, or the clock was
    /// set back to before the last check.
    public static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// Whether a due automatic check (the timer, waking up) may start: not while the update window
    /// shows an offered update or a failed installation — the check would replace what the user
    /// is reading, and its Download or Try Again button. Once the window is closed (Remind Me
    /// Later), checks run as before. Checks the user asks for always run.
    public static func mayCheckAutomatically(showsOfferOrFailure: Bool, windowIsShown: @autoclosure () -> Bool) -> Bool {
        !(showsOfferOrFailure && windowIsShown())
    }
}

/// Fixed addresses the updater and its windows link to.
public enum UpdateLinks {
    public static let repositoryOwner = "ercanatay"
    public static let repositoryName = "cybokron-limit-guard"
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ercanatay/cybokron-limit-guard/releases/latest")!
    /// Every release, newest first (GitHub's maximum page size).
    public static let releasesAPI = URL(string: "https://api.github.com/repos/ercanatay/cybokron-limit-guard/releases?per_page=100")!
    /// The newest 30 releases, newest first, for Settings → Changelog.
    public static let changelogReleasesAPI = URL(string: "https://api.github.com/repos/ercanatay/cybokron-limit-guard/releases?per_page=30")!
    public static let releasesPage = URL(string: "https://github.com/ercanatay/cybokron-limit-guard/releases")!
    /// The changelog as a plain text file on GitHub.
    public static let changelog = URL(string: "https://raw.githubusercontent.com/ercanatay/cybokron-limit-guard/main/CHANGELOG.md")!
}
