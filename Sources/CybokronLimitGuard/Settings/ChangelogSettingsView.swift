import LimitGuardCore
import SwiftUI

/// Settings → Changelog: the running version, when the release list was last loaded (with Refresh),
/// and the notes of every published release, newest first — the newest open, the others closed.
///
/// The list comes from `ChangelogService`: the copy saved last time shows right away, and showing
/// the pane refreshes it in the background when it's older than a few minutes. A failed refresh
/// keeps the copy on screen and says so in one line.
struct ChangelogSettingsView: View {
    @ObservedObject var changelog: ChangelogService

    /// Releases opened or closed by hand; the others follow the default (only the newest open).
    @State private var expansion: [String: Bool] = [:]

    var body: some View {
        Form {
            Section {
                statusRow
                if let reason = changelog.refreshError, !changelog.entries.isEmpty {
                    cachedCopyHint(reason)
                }
            }

            Section {
                releases
            } header: {
                Text(L10n.Changelog.header)
            } footer: {
                Text(L10n.Changelog.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        // Release notes are written by whoever publishes a release: only web and mail links open.
        .environment(\.openURL, .clickableLinksOnly)
        .onAppear { changelog.refreshIfStale() }
    }

    /// "Current version: 0.6.0", then when the list was loaded and the Refresh button.
    private var statusRow: some View {
        HStack(spacing: 8) {
            Text(L10n.Changelog.currentVersion(AppInfo.version))
                .textSelection(.enabled)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if changelog.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            if let date = changelog.lastUpdated {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(L10n.Changelog.lastUpdated(Self.relative(date, now: context.date)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
                .layoutPriority(1)
            }
            Button(L10n.Changelog.refresh, systemImage: "arrow.clockwise") {
                changelog.refresh()
            }
            .labelStyle(.iconOnly)
            .disabled(changelog.isRefreshing)
            .help(L10n.Changelog.refreshHelp)
        }
    }

    /// Under the status row when a refresh failed but the saved copy is shown.
    private func cachedCopyHint(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(L10n.Changelog.showingCachedCopy, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text([reason, L10n.Changelog.retryHint].joined(separator: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var releases: some View {
        if changelog.entries.isEmpty {
            emptyState
        } else {
            ForEach(changelog.entries) { entry in
                DisclosureGroup(isExpanded: isExpanded(entry)) {
                    ChangelogNotesView(entry: entry)
                } label: {
                    ReleaseTitleView(entry: entry, badges: changelog.badges(for: entry))
                }
            }
        }
    }

    /// No saved copy yet: loading for the first time, or that failed.
    @ViewBuilder
    private var emptyState: some View {
        if changelog.isRefreshing {
            Text(L10n.Changelog.loading)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.Changelog.unavailable, systemImage: "newspaper")
                Text([changelog.refreshError, L10n.Changelog.retryHint].compactMap { $0 }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isExpanded(_ entry: ChangelogEntry) -> Binding<Bool> {
        Binding(
            get: { expansion[entry.tagName] ?? (entry.tagName == changelog.entries.first?.tagName) },
            set: { expansion[entry.tagName] = $0 }
        )
    }

    /// "now" under a minute (and for a clock set back), then "3 minutes ago", "2 hours ago", … in the
    /// app's language.
    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: now.timeIntervalSince(date) < 60 ? now : date, relativeTo: now)
    }
}

/// A release's row: its version and publication date, then its badges.
private struct ReleaseTitleView: View {
    let entry: ChangelogEntry
    let badges: ChangelogBadges

    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.Common.version(entry.version.description))
                .font(.body.monospacedDigit().weight(.semibold))
            if let date = entry.publishedAt {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.secondary)
            }
            if badges.contains(.latest) {
                BadgeView(text: L10n.Changelog.latest, color: .green)
            }
            if badges.contains(.prerelease) {
                BadgeView(text: L10n.Changelog.prerelease, color: .orange)
            }
            if badges.contains(.installed) {
                BadgeView(text: L10n.Changelog.installed, color: .accentColor)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// An open release: its title (when it has one besides the version), its notes, and a link to its
/// page on GitHub.
private struct ChangelogNotesView: View {
    let entry: ChangelogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = entry.title {
                Text(title)
                    .font(.headline)
            }
            let blocks = entry.noteBlocks
            if blocks.isEmpty {
                Text(L10n.Changelog.noNotes)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    ReleaseNotesBlockView(block: block)
                }
            }
            if let url = entry.pageURL {
                Link(destination: url) {
                    Label(L10n.Changelog.openRelease, systemImage: "arrow.up.right.square")
                }
                .font(.callout)
                .padding(.top, 2)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// One block of release notes; see `ReleaseNotesMarkdown`.
private struct ReleaseNotesBlockView: View {
    let block: ReleaseNotesBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(ReleaseNotesMarkdown.inline(text))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(ReleaseNotesMarkdown.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .paragraph(let text):
            Text(ReleaseNotesMarkdown.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
        case .rule:
            Divider()
        }
    }
}
