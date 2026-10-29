import LimitGuardCore
import SwiftUI

/// Settings → Updates → "Other Versions…": the published releases (no drafts or prereleases), newest
/// first, each with Install — older or newer than the running version. Installing asks first — for
/// a version older than `ReleaseHistory.minimumSecurityVersion`, with a warning that it lacks the
/// security fixes; for an older one, with a note that a copy of the data files is kept
/// (`DowngradeProtection`) — then closes the sheet and follows in the update window like any
/// update. When a check or another installation started meanwhile, it says so instead of doing
/// nothing.
struct OtherVersionsView: View {
    @ObservedObject var updater: AutoUpdater
    let dismiss: () -> Void

    @State private var pending: PendingInstall?
    @State private var isBusyNoticeShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Settings.OtherVersions.title)
                .font(.headline)
            Text(L10n.Settings.OtherVersions.intro(AppInfo.name))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
                .frame(height: 260)
            HStack {
                Link(L10n.Settings.OtherVersions.releasesOnGitHub, destination: UpdateLinks.releasesPage)
                    .font(.callout)
                Spacer()
                Button(L10n.Common.done, action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { updater.loadReleases() }
        .alert(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Common.install) {
                guard !updater.isBusy else {
                    // After this alert has gone.
                    DispatchQueue.main.async { isBusyNoticeShown = true }
                    return
                }
                dismiss()
                updater.installPicked(pending.release, from: pending.releases)
            }
        } message: { pending in
            Text(pending.message)
        }
        .alert(L10n.Settings.OtherVersions.busyTitle, isPresented: $isBusyNoticeShown) {
            Button(L10n.Common.ok) {}
        } message: {
            Text(L10n.Settings.OtherVersions.busyMessage(AppInfo.name))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.releaseList {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text(L10n.Settings.OtherVersions.loading)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.Common.tryAgain) { updater.loadReleases(force: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let releases) where releases.isEmpty:
            Text(L10n.Settings.OtherVersions.none)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let releases):
            List(releases, id: \.tagName) { release in
                row(release, in: releases)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func row(_ release: ReleaseInfo, in releases: [ReleaseInfo]) -> some View {
        let isCurrent = release.version == updater.currentVersion
        let hasInstaller = release.installerAsset != nil
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Common.version(release.version.description))
                    .font(.body.monospacedDigit().weight(isCurrent ? .semibold : .regular))
                if let date = release.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isCurrent {
                Text(L10n.Settings.OtherVersions.current)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if !isCurrent {
                if !hasInstaller {
                    Text(L10n.Settings.OtherVersions.noDownload)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(L10n.Common.install) {
                    pending = PendingInstall(
                        release: release,
                        releases: releases,
                        current: updater.currentVersion
                    )
                }
                .disabled(!hasInstaller || updater.isBusy)
                .help(hasInstaller
                    ? L10n.Settings.OtherVersions.installHelp(release.version.description)
                    : L10n.Settings.OtherVersions.noDiskImage)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A version waiting for confirmation, with what installing it means.
private struct PendingInstall {
    let release: ReleaseInfo
    let releases: [ReleaseInfo]
    let current: SemanticVersion?
    private var target: SemanticVersion { release.version }

    private var change: VersionChange? {
        current.map { ReleaseHistory.change(from: $0, to: target) }
    }

    /// The version predates the security fixes (`ReleaseHistory.minimumSecurityVersion`): the
    /// question says so first.
    private var lacksSecurityFixes: Bool {
        ReleaseHistory.lacksSecurityFixes(target)
    }

    var title: String {
        lacksSecurityFixes
            ? L10n.Settings.OtherVersions.preSafetyTitle
            : L10n.Settings.OtherVersions.confirmTitle(target.description)
    }

    var message: String {
        var parts: [String] = []
        if lacksSecurityFixes {
            parts.append(L10n.Settings.OtherVersions.preSafetyMessage(target.description))
        }
        parts.append(L10n.Settings.OtherVersions.confirmQuits(AppInfo.name, version: target.description))
        switch change {
        case .downgrade:
            let newer = current.map { ReleaseHistory.versionsSkipped(goingBackTo: target, from: $0, in: releases) }?.map(\.description) ?? []
            if target < ReleaseHistory.firstSelfUpdatingVersion {
                parts.append(L10n.Settings.OtherVersions.confirmCantUpdate(target.description))
            } else if !newer.isEmpty {
                parts.append(L10n.Settings.OtherVersions.confirmSkips(newer.joined(separator: ", ")))
            }
            parts.append(L10n.Settings.OtherVersions.dataCopiesNote)
            parts.append(L10n.Settings.OtherVersions.confirmOlder)
        case .upgrade:
            parts.append(L10n.Settings.OtherVersions.confirmUpgrade)
        case .reinstall, nil:
            break
        }
        return parts.joined(separator: " ")
    }
}
