import LimitGuardCore
import SwiftUI

/// Updates: automatic checks, checking right away, when the last check ran and what it found, the
/// skipped versions, installing another published version, and links to the releases and the
/// changelog.
struct UpdatesSettingsView: View {
    @ObservedObject var updater: AutoUpdater

    @State private var isShowingOtherVersions = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.Settings.Updates.automatic, isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
                LabeledContent(L10n.Settings.Updates.currentVersion) {
                    Text(L10n.Common.version(AppInfo.version))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent(L10n.Settings.Updates.lastChecked) {
                    Text(lastChecked)
                        .foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button(L10n.Settings.Updates.checkNow) { updater.checkNow() }
                        .disabled(updater.isBusy)
                } label: {
                    status
                }
                LabeledContent {
                    Button(L10n.Settings.Updates.otherVersions) { isShowingOtherVersions = true }
                        .disabled(updater.isBusy)
                } label: {
                    skippedVersions
                }
            } header: {
                Text(L10n.Settings.updatesTab)
            } footer: {
                Text(L10n.Settings.Updates.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Link(destination: UpdateLinks.releasesPage) {
                    Label(L10n.Common.openReleasesPage, systemImage: "arrow.up.right.square")
                }
                Link(destination: UpdateLinks.changelog) {
                    Label(L10n.Settings.Updates.viewChangelog, systemImage: "doc.text")
                }
            } header: {
                Text(L10n.Common.links)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .sheet(isPresented: $isShowingOtherVersions) {
            OtherVersionsView(updater: updater) { isShowingOtherVersions = false }
        }
    }

    /// Which newer versions automatic checks skip, next to "Other Versions…". Skips of versions not
    /// newer than the running one don't matter any more and aren't shown.
    @ViewBuilder
    private var skippedVersions: some View {
        let newer = updater.skippedVersions.filter { skipped in
            guard let current = updater.currentVersion, let version = SemanticVersion(skipped) else { return true }
            return version > current
        }
        if newer.isEmpty {
            Text(L10n.Settings.Updates.latestPath)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                Text(L10n.Settings.Updates.skippedVersions(newer.joined(separator: ", ")))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.Settings.Updates.clear) { updater.clearSkippedVersions() }
                    .controlSize(.small)
                    .help(L10n.Settings.Updates.clearHelp)
            }
        }
    }

    private var lastChecked: String {
        guard let date = updater.lastCheckDate else { return L10n.Settings.Updates.never }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// One line about the latest check, under the Check Now button's label.
    @ViewBuilder
    private var status: some View {
        switch updater.status {
        case .idle:
            Text(L10n.Settings.Updates.notChecked)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.Settings.Updates.checking)
            }
        case .upToDate(let version):
            Label(L10n.Settings.Updates.upToDate(version.description), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let release, _), .stagedForDryRun(let release, _):
            HStack(spacing: 8) {
                Label(L10n.Settings.Updates.available(release.version.description), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Button(L10n.Settings.Updates.showUpdate) { updater.showWindow() }
                    .controlSize(.small)
            }
        case .downloading(let release, _), .installing(let release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.Common.installingVersion(release.version.description))
            }
        case .restarting(let release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.Common.installedRestarting(release.version.description))
            }
        case .checkFailed(let message), .installFailed(_, _, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
