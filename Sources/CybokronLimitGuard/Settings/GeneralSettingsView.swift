import AppKit
import LimitGuardCore
import SwiftUI

/// General: start-up and menu bar behaviour, the Codex executable, the language, and the legal
/// notice and diagnostics.
struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    let runDiagnostics: () -> Void

    /// What the automatic lookup (or the override) resolves to now; nil while looking or when absent.
    @State private var resolvedCodex: URL?
    @State private var isResolving = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsStatusBanner(model: model)
            Form {
                startupSection
                codexSection
                languageSection
                noticeSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 480)
        .task(id: model.settings.codexPathOverride) { await resolveCodex() }
    }

    private var startupSection: some View {
        Section {
            Toggle(L10n.Settings.General.launchAtLogin, isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if model.loginItemState == .requiresApproval || model.loginItemError != nil {
                LabeledContent {
                    Button(L10n.Settings.General.openLoginItems) { LoginItem.openSystemSettings() }
                } label: {
                    Text(model.loginItemError.map(L10n.Settings.General.launchFailed) ?? L10n.Settings.General.launchNeedsApproval)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(L10n.Settings.General.showPercent, isOn: model.binding(\.showPercentInMenuBar))
            Toggle(L10n.Settings.General.keepAwake, isOn: model.binding(\.keepAwake))
            caption(L10n.Settings.General.keepAwakeHelp)
            Toggle(L10n.Settings.General.guardNewTabs, isOn: model.binding(\.guardNewTabsAutomatically))
            caption(L10n.Settings.General.guardNewTabsHelp)
        }
        .disabled(model.isReadOnly)
    }

    private var codexSection: some View {
        Section {
            LabeledContent(L10n.Settings.General.codexPath) {
                Text(codexDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            if overrideIsInvalid {
                caption(L10n.Settings.General.codexOverrideInvalid)
            }
            HStack {
                Button(L10n.Settings.General.codexChoose) { chooseCodex() }
                Button(L10n.Settings.General.codexReveal) {
                    if let resolvedCodex { NSWorkspace.shared.activateFileViewerSelecting([resolvedCodex]) }
                }
                .disabled(resolvedCodex == nil)
                Button(L10n.Settings.General.codexReset) {
                    model.mutate { $0.codexPathOverride = nil }
                }
                .disabled(model.settings.codexPathOverride == nil)
            }
        } header: {
            Text(L10n.Settings.General.codexHeader)
        }
        .disabled(model.isReadOnly)
    }

    private var languageSection: some View {
        Section {
            Picker(L10n.Settings.General.language, selection: Binding(
                get: { model.settings.language },
                set: { model.setLanguage($0) }
            )) {
                Text(L10n.Settings.General.languageSystem).tag(AppLanguage.system)
                Text(L10n.Settings.General.languageEnglish).tag(AppLanguage.english)
                Text(L10n.Settings.General.languageTurkish).tag(AppLanguage.turkish)
            }
        } header: {
            Text(L10n.Settings.General.languageHeader)
        }
        .disabled(model.isReadOnly)
    }

    private var noticeSection: some View {
        Section {
            HStack {
                Button(L10n.Settings.General.showNotice) { LegalNoticeWindow.show(mode: .review) }
                Button(L10n.Settings.General.runDiagnostics) { runDiagnostics() }
            }
        } header: {
            Text(L10n.Settings.General.aboutHeader)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Codex path

    private var codexDescription: String {
        if let resolvedCodex { return resolvedCodex.path }
        if isResolving { return "…" }
        return L10n.Settings.General.codexNotFound
    }

    private var overrideIsInvalid: Bool {
        guard let path = model.settings.codexPathOverride else { return false }
        return !FileManager.default.isExecutableFile(atPath: (path as NSString).expandingTildeInPath)
    }

    private func resolveCodex() async {
        #if DEBUG
        if ScreenshotMode.isActive {
            resolvedCodex = ScreenshotMode.codexPath
            return
        }
        #endif
        isResolving = true
        let override = model.settings.codexPathOverride
        // The automatic lookup asks a login shell: off the main thread.
        resolvedCodex = await Task.detached { CodexLocator().resolve(override: override) }.value
        isResolving = false
    }

    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.message = L10n.Settings.General.codexPanelMessage
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.mutate { $0.codexPathOverride = url.path }
    }
}
