import Combine
import Foundation
import OSLog

/// The releases Settings → Changelog lists: the copy saved last time, shown right away (offline
/// too), refreshed from GitHub in the background.
///
/// - The saved copy (`changelog-cache.json`) is read when the service is made, so once the list has
///   loaded the pane never opens empty or waits for the network.
/// - `refreshIfStale()` (the pane appearing) asks GitHub only when the copy is older than
///   `automaticRefreshInterval` and no refresh was tried in that time either; `refresh()` (the
///   Refresh button) asks right away. Both send the copy's ETag, so an unchanged list costs an empty
///   304 answer.
/// - A refresh that fails — offline, GitHub's rate limit (HTTP 403/429), an unreadable answer —
///   keeps the copy and says why in `refreshError`, until a refresh succeeds.
@MainActor
public final class ChangelogService: ObservableObject {
    /// How old the copy may get before showing the pane refreshes it, and how long after a refresh
    /// was tried (successfully or not) showing it doesn't try again: switching panes back and forth
    /// shouldn't use up GitHub's hourly limit.
    public static let automaticRefreshInterval: TimeInterval = 10 * 60

    /// Newest first; see `sorted(_:)`.
    @Published public private(set) var entries: [ChangelogEntry]
    /// When GitHub last sent the list or confirmed it, `nil` before it ever did.
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var isRefreshing = false
    /// Why the latest refresh failed, `nil` once one succeeds (and before any is tried).
    @Published public private(set) var refreshError: String?
    /// The running app's version, for the Installed badge; `nil` when the bundle has none.
    public let currentVersion: SemanticVersion?

    private let fetcher: ChangelogFetching
    private let persistence: ChangelogCachePersisting
    private let now: () -> Date
    private var cache: ChangelogCache?
    private var refreshTask: Task<Void, Never>?
    private var lastAttempt: Date?
    private let logger = Logger(subsystem: "com.cybokron.limitguard", category: "Changelog")

    public init(
        fetcher: ChangelogFetching,
        persistence: ChangelogCachePersisting = JSONFileChangelogCachePersistence(),
        currentVersion: SemanticVersion?,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetcher = fetcher
        self.persistence = persistence
        self.currentVersion = currentVersion
        self.now = now
        let cache = persistence.load().map { saved in
            ChangelogCache(fetchedAt: saved.fetchedAt, etag: saved.etag, entries: Self.sorted(saved.entries))
        }
        self.cache = cache
        entries = cache?.entries ?? []
        // A cache without its date (counted as 1970) is refreshed, but has no date worth showing.
        lastUpdated = cache.map(\.fetchedAt).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }

    /// Whether showing the pane should refresh: the copy is older than `automaticRefreshInterval`
    /// (or there's none), and so is the latest try.
    public var isStale: Bool {
        let latest = [lastUpdated, lastAttempt].compactMap { $0 }.max()
        return UpdateSchedule.isCheckDue(lastCheck: latest, now: now(), interval: Self.automaticRefreshInterval)
    }

    /// Refreshes when `isStale`; returns the refresh under way, if any.
    @discardableResult
    public func refreshIfStale() -> Task<Void, Never>? {
        guard isStale else { return refreshTask }
        return refresh()
    }

    /// Asks GitHub for the list now, unless that's under way already; returns the refresh. The
    /// entries stay as they are until it ends.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        lastAttempt = now()
        isRefreshing = true
        // Without entries a 304 would leave nothing to show, so then the whole list is asked for.
        let etag = entries.isEmpty ? nil : cache?.etag
        logger.notice("Refreshing the changelog\(etag == nil ? "" : " (conditional)", privacy: .public)")
        let task = Task { @MainActor [weak self, fetcher] in
            let result: Result<ChangelogFetchResult, Error>
            do {
                result = .success(try await fetcher.releases(ifNoneMatch: etag))
            } catch {
                result = .failure(error)
            }
            self?.finishRefresh(result)
        }
        refreshTask = task
        return task
    }

    /// The badges next to `entry`'s version.
    public func badges(for entry: ChangelogEntry) -> ChangelogBadges {
        Self.badges(for: entry, in: entries, currentVersion: currentVersion)
    }

    private func finishRefresh(_ result: Result<ChangelogFetchResult, Error>) {
        refreshTask = nil
        isRefreshing = false
        switch result {
        case .success(.releases(let releases, let etag)):
            let cache = ChangelogCache(fetchedAt: now(), etag: etag, entries: Self.entries(from: releases))
            logger.notice("Changelog loaded: \(cache.entries.count) releases")
            store(cache)
            refreshError = nil
        case .success(.notModified):
            logger.notice("Changelog unchanged")
            if var cache = self.cache {
                cache.fetchedAt = now()
                store(cache)
            }
            refreshError = nil
        case .failure(let error):
            if error is CancellationError { return }
            logger.error("Refreshing the changelog failed: \(String(describing: error), privacy: .public)")
            refreshError = error.localizedDescription
        }
    }

    private func store(_ cache: ChangelogCache) {
        self.cache = cache
        entries = cache.entries
        lastUpdated = cache.fetchedAt
        do {
            try persistence.save(cache)
        } catch {
            logger.error("Saving the changelog cache failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Listing

    /// The releases to list: every published one, prereleases included (they get a badge), drafts
    /// left out, one per version (the first listed wins), newest first.
    public nonisolated static func entries(from releases: [ReleaseInfo]) -> [ChangelogEntry] {
        var seen: Set<SemanticVersion> = []
        return sorted(releases
            .filter { !$0.isDraft }
            .filter { seen.insert($0.version).inserted }
            .map(ChangelogEntry.init))
    }

    /// Newest first: by publication date, with releases that have none at the end; the same date by
    /// version, newest first.
    public nonisolated static func sorted(_ entries: [ChangelogEntry]) -> [ChangelogEntry] {
        entries.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.version == rhs.version ? lhs.tagName < rhs.tagName : lhs.version > rhs.version
            }
        }
    }

    /// `entry`'s badges among `entries` (newest first): Latest for the newest that isn't a
    /// prerelease, as GitHub marks it; Installed for `currentVersion`; Pre-release.
    public nonisolated static func badges(for entry: ChangelogEntry, in entries: [ChangelogEntry], currentVersion: SemanticVersion?) -> ChangelogBadges {
        var badges: ChangelogBadges = []
        if entry.isPrerelease {
            badges.insert(.prerelease)
        } else if entries.first(where: { !$0.isPrerelease })?.tagName == entry.tagName {
            badges.insert(.latest)
        }
        if let currentVersion, entry.version == currentVersion {
            badges.insert(.installed)
        }
        return badges
    }
}
