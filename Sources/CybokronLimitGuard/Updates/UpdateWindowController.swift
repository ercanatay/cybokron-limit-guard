import AppKit
import LimitGuardCore
import SwiftUI

/// The update window: a small, non-modal window that follows `AutoUpdater` — checking, up to date,
/// a new version with its release notes, download progress, or what went wrong. It never blocks the
/// app (no alert or modal session), so the menu bar keeps working while it's open.
@MainActor
final class UpdateWindowController: NSWindowController {
    init(updater: AutoUpdater) {
        let hostingController = NSHostingController(rootView: UpdateView(updater: updater))
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.UpdateWindow.title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings the app to the front.
    func show() {
        NSApp.activate()
        if let window, !window.isVisible {
            window.layoutIfNeeded()
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateView: View {
    static let width: CGFloat = 500

    @ObservedObject var updater: AutoUpdater

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.openURL, .clickableLinksOnly)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.status {
        case .idle, .checking:
            title(L10n.UpdateWindow.checking)
            ProgressView()
                .progressViewStyle(.linear)
            buttons {
                Spacer()
                Button(L10n.Common.cancel) { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
            }

        case .upToDate(let version):
            title(L10n.UpdateWindow.upToDateTitle)
            Text(L10n.UpdateWindow.upToDateMessage(AppInfo.name, version: version.description))
                .foregroundStyle(.secondary)
            links(pageURL: nil)
            buttons {
                Spacer()
                Button(L10n.Common.ok) { updater.remindLater() }
                    .keyboardShortcut(.defaultAction)
            }

        case .available(let release, let asset):
            title(L10n.UpdateWindow.availableTitle(AppInfo.name))
            Text([
                L10n.UpdateWindow.availableMessage(release.version.description, current: currentVersionText),
                asset == nil ? L10n.UpdateWindow.availableNoDiskImage : L10n.UpdateWindow.availableQuestion,
            ].joined(separator: " "))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ReleaseNotesView(release: release)
            links(pageURL: release.pageURL)
            buttons {
                Button(L10n.UpdateWindow.skipVersion) { updater.skip(release) }
                Spacer()
                Button(L10n.UpdateWindow.remindLater) { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                if asset == nil {
                    Button(L10n.UpdateWindow.openReleasePage) { open(release.pageURL ?? UpdateLinks.releasesPage) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.UpdateWindow.downloadAndInstall) { updater.downloadAndInstall() }
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .downloading(let release, let fraction):
            title(L10n.UpdateWindow.downloading(release.version.description))
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
            Text(min(max(fraction, 0), 1), format: .percent.precision(.fractionLength(0)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

        case .installing(let release):
            title(L10n.Common.installingVersion(release.version.description))
            ProgressView()
                .progressViewStyle(.linear)
            Text(L10n.UpdateWindow.restartsWhenDone(AppInfo.name))
                .foregroundStyle(.secondary)

        case .restarting(let release):
            title(L10n.Common.installedRestarting(release.version.description))
            ProgressView()
                .progressViewStyle(.linear)
            Text(L10n.UpdateWindow.reopening(AppInfo.name))
                .foregroundStyle(.secondary)

        case .stagedForDryRun(let release, let path):
            title(L10n.UpdateWindow.dryRunTitle)
            Text(L10n.UpdateWindow.dryRunMessage(release.version.description, path: path))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Spacer()
                Button(L10n.Common.ok) { updater.remindLater() }
                    .keyboardShortcut(.defaultAction)
            }

        case .checkFailed(let message):
            title(L10n.UpdateWindow.checkFailed)
            failure(message)
            links(pageURL: nil)
            buttons {
                Button(L10n.Common.openReleasesPage) { open(UpdateLinks.releasesPage) }
                Spacer()
                Button(L10n.Common.close) { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.Common.tryAgain) { updater.checkNow() }
                    .keyboardShortcut(.defaultAction)
            }

        case .installFailed(let release, let asset, let message):
            title(L10n.UpdateWindow.installFailed(release.version.description))
            failure(message)
            links(pageURL: release.pageURL)
            buttons {
                Button(L10n.UpdateWindow.openReleasePage) { open(release.pageURL ?? UpdateLinks.releasesPage) }
                Spacer()
                Button(L10n.Common.close) { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                if asset != nil {
                    Button(L10n.Common.tryAgain) { updater.downloadAndInstall() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var currentVersionText: String {
        updater.currentVersion?.description ?? AppInfo.version
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func links(pageURL: URL?) -> some View {
        HStack(spacing: 16) {
            Link(L10n.Common.changelog, destination: UpdateLinks.changelog)
            Link(
                pageURL == nil ? L10n.UpdateWindow.releasesLink : L10n.UpdateWindow.releasePageLink,
                destination: pageURL ?? UpdateLinks.releasesPage
            )
        }
        .font(.callout)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            content()
        }
        .padding(.top, 4)
    }

    /// A release's page comes from the release information; anything but a web page opens the
    /// releases page instead.
    private func open(_ url: URL) {
        NSWorkspace.shared.open(LinkPolicy.isClickable(url) ? url : UpdateLinks.releasesPage)
    }
}

/// The release notes, scrollable. GitHub's notes are Markdown; headings and list bullets are
/// simplified so inline Markdown (bold, links, code) renders.
private struct ReleaseNotesView: View {
    let release: ReleaseInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.UpdateWindow.releaseNotes)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }

    /// Only `https` and `mailto` links stay clickable (`LinkPolicy`).
    private var notes: AttributedString {
        ReleaseNotesMarkdown.compact(release.notes) ?? AttributedString(L10n.UpdateWindow.noReleaseNotes)
    }
}

extension OpenURLAction {
    /// Opens only the links `LinkPolicy.isClickable` allows (`https`, `mailto`) and drops the rest,
    /// for the windows that show release notes.
    static let clickableLinksOnly = OpenURLAction { url in
        LinkPolicy.isClickable(url) ? .systemAction : .discarded
    }
}
