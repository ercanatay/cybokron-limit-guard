import AppKit
import LimitGuardCore
import SwiftUI

/// The popover, top to bottom (spec §4.2): status line, 5-hour bar, weekly bar, next action,
/// usage limit resets, Codex sessions, footer.
struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    let closePopover: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let palette = PanelPalette.forScheme(colorScheme)
        let maxHeight = PopoverLayout.maxContentHeight(visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? 800)
        VStack(alignment: .leading, spacing: 0) {
            // Sizes to its content while short; scrolls once it would outgrow the screen.
            ScrollView(.vertical) {
                content(palette)
                    .frame(width: 380, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight)
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            Divider().overlay(palette.hairline)
            PopoverFooter(engine: model.engine, model: model, palette: palette, closePopover: closePopover)
        }
        .frame(width: 380)
        .background(palette.glassTint)
    }

    @ViewBuilder private func content(_ palette: PanelPalette) -> some View {
        if let engine = model.engine {
            EngineSections(engine: engine, model: model, palette: palette, closePopover: closePopover)
        } else {
            StatusLine(text: L10n.EngineStatus.starting, symbol: "hourglass", tint: palette.secondaryText, palette: palette)
                .padding(14)
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Everything that follows the Engine's published state.
private struct EngineSections: View {
    @ObservedObject var engine: Engine
    @ObservedObject var model: PopoverModel
    let palette: PanelPalette
    let closePopover: () -> Void

    private var isReadOnly: Bool {
        if case .readOnly = engine.health { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection
            LimitBarView(
                title: L10n.Popover.Limit.fiveHour, window: engine.snapshot?.fiveHour,
                forecast: engine.forecast.fiveHour, forecastText: L10n.Popover.Limit.fiveHourForecast,
                clockTemplate: "jmm", palette: palette)
            LimitBarView(
                title: L10n.Popover.Limit.weekly, window: engine.snapshot?.weekly,
                forecast: engine.forecast.weekly, forecastText: L10n.Chart.forecast,
                clockTemplate: "EEEdMMMjmm", palette: palette)
            if let next = engine.nextAction {
                NextActionView(action: next, tabs: engine.tabs, palette: palette) { engine.cancelNextAction() }
            }
            ResetCreditsView(engine: engine, model: model, isReadOnly: isReadOnly, palette: palette)
            GuardedTabsView(engine: engine, model: model, isReadOnly: isReadOnly, palette: palette)
        }
        .padding(14)
    }

    @ViewBuilder private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            status
            if case let .readOnly(reason) = engine.health {
                StatusLine(text: L10n.Popover.Status.readOnly, symbol: "lock.fill", tint: .orange, palette: palette)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if model.settingsUnreadable {
                HStack(spacing: 6) {
                    StatusLine(text: L10n.Popover.Status.settingsUnreadable, symbol: "exclamationmark.triangle.fill", tint: .orange, palette: palette)
                    Spacer(minLength: 4)
                    Button(L10n.Settings.Reset.button) {
                        closePopover()
                        model.actions.resetSettings()
                    }
                    .controlSize(.small)
                }
            }
            if model.notificationsAllowed == false {
                HStack(spacing: 6) {
                    StatusLine(text: L10n.Popover.Status.notificationsOff, symbol: "bell.slash", tint: palette.secondaryText, palette: palette)
                    Spacer(minLength: 4)
                    Button(L10n.Popover.Status.openNotificationSettings) {
                        closePopover()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        let state = PopoverStatus.make(
            engineRunning: true, codexFound: model.codexFound, hasSnapshot: engine.snapshot != nil,
            readFailure: engine.readFailure, isPaused: engine.isPaused, tabCount: engine.tabs.count,
            guardedCount: engine.tabs.filter(\.isGuarded).count)
        switch state {
        case .starting:
            StatusLine(text: L10n.EngineStatus.starting, symbol: "hourglass", tint: palette.secondaryText, palette: palette)
        case .codexMissing:
            HStack(spacing: 6) {
                StatusLine(text: L10n.Popover.Status.codexMissing, symbol: "exclamationmark.triangle.fill", tint: .red, palette: palette)
                Spacer(minLength: 4)
                Button(L10n.Settings.menuItem) {
                    closePopover()
                    model.actions.showSettings()
                }
                .controlSize(.small)
            }
        case .notSignedIn:
            StatusLine(text: L10n.Popover.Status.notSignedIn, symbol: "person.crop.circle.badge.exclamationmark", tint: .red, palette: palette)
        case .readFailed:
            StatusLine(text: L10n.Popover.Status.readFailed, symbol: "exclamationmark.triangle.fill", tint: .orange, palette: palette)
        case .reading:
            StatusLine(text: L10n.EngineStatus.reading, symbol: "arrow.triangle.2.circlepath", tint: palette.secondaryText, palette: palette)
        case .paused:
            StatusLine(text: L10n.EngineStatus.paused, symbol: "pause.circle.fill", tint: .orange, palette: palette)
        case .noCodexTab:
            StatusLine(text: L10n.Popover.Status.noCodexTab, symbol: "terminal", tint: palette.secondaryText, palette: palette)
        case let .watching(guarded) where guarded == 0:
            StatusLine(text: L10n.Popover.Status.noneGuarded, symbol: "eye.slash", tint: palette.secondaryText, palette: palette)
        case let .watching(guarded):
            StatusLine(text: L10n.Popover.Status.watching(guarded), symbol: "eye.fill", tint: PanelPalette.teal, palette: palette)
        }
    }
}

/// One line with a symbol, as the status line and its banners use it.
struct StatusLine: View {
    let text: String
    let symbol: String
    let tint: Color
    let palette: PanelPalette

    var body: some View {
        Label {
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// A section heading, with optional content on the right (the "N available" chip).
struct SectionHeader<Trailing: View>: View {
    let title: String
    let palette: PanelPalette
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primaryText)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, palette: PanelPalette) {
        self.init(title: title, palette: palette) { EmptyView() }
    }
}

/// Pause/Resume, the windows, About, Quit, and the account's plan.
private struct PopoverFooter: View {
    let engine: Engine?
    @ObservedObject var model: PopoverModel
    let palette: PanelPalette
    let closePopover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let engine {
                    PauseButton(engine: engine)
                }
                Spacer(minLength: 4)
                if let engine {
                    PlanLabel(engine: engine, palette: palette)
                }
            }
            HStack(spacing: 6) {
                footerButton(L10n.Popover.Footer.activity, help: L10n.Activity.menuItem) { model.actions.showActivity() }
                footerButton(L10n.Popover.Footer.chart, help: L10n.Chart.menuItem) { model.actions.showChart() }
                footerButton(L10n.Popover.Footer.settings, help: L10n.Settings.menuItem) { model.actions.showSettings() }
                footerButton(L10n.Popover.Footer.about, help: L10n.Common.about(L10n.App.name)) { model.actions.showAbout() }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label(L10n.Popover.Footer.quit, systemImage: "power")
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help(L10n.Menu.quit(L10n.App.name))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func footerButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            closePopover()
            action()
        } label: {
            Text(title)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }
}

private struct PauseButton: View {
    @ObservedObject var engine: Engine

    var body: some View {
        Button {
            engine.pause(!engine.isPaused)
        } label: {
            Label(
                engine.isPaused ? L10n.Popover.Footer.resume : L10n.Popover.Footer.pause,
                systemImage: engine.isPaused ? "play.fill" : "pause.fill")
        }
        .controlSize(.small)
        .help(L10n.Popover.Footer.pauseHelp)
    }
}

/// The active account's plan, small (spec §4.4).
private struct PlanLabel: View {
    @ObservedObject var engine: Engine
    let palette: PanelPalette

    var body: some View {
        if let plan = engine.snapshot?.planType, !plan.isEmpty {
            Text(L10n.Popover.Footer.plan(plan))
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
        }
    }
}
