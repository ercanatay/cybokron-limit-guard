import Foundation
import LimitGuardCore
import SwiftUI

/// "Codex sessions" (spec §7.3 "Guarded tabs", D19): every Terminal tab running Codex with a
/// checkbox; an unticked or settled waiting tab offers Continue now, an unconfirmed continue offers
/// Send again, an unclear one says to continue by hand.
struct GuardedTabsView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var model: PopoverModel
    let isReadOnly: Bool
    let palette: PanelPalette

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.s) {
            SectionHeader(title: L10n.Popover.Sessions.title, palette: palette)
            let rows = SessionsPresentation.rows(tabs: engine.tabs, sessions: engine.sessions, snapshot: engine.snapshot, now: Date())
            PanelCard(palette: palette) {
                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: PanelMetrics.xs) {
                        Text(L10n.Popover.Sessions.empty)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(palette.primaryText)
                        Text(L10n.Popover.Sessions.none)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: PanelMetrics.m) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider().overlay(palette.hairline) }
                            SessionRowView(
                                row: row, model: model, palette: palette,
                                canContinue: !isReadOnly && engine.snapshot?.ordinaryUsageAllowed == true,
                                paused: engine.isPaused, autoContinue: model.autoContinue,
                                setGuarded: { engine.setGuarded(row.ref, $0) })
                        }
                        Text(L10n.Popover.Sessions.guardHelp)
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    @ObservedObject var model: PopoverModel
    let palette: PanelPalette
    let canContinue: Bool
    let paused: Bool
    let autoContinue: Bool
    let setGuarded: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.xs) {
            HStack(alignment: .top, spacing: PanelMetrics.s) {
                Toggle(isOn: Binding(get: { row.isGuarded }, set: setGuarded)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let name = row.threadTitle {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(palette.primaryText.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text(details)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(row.title)
                Spacer(minLength: PanelMetrics.xs)
                pill
            }
            detail
                .padding(.leading, 22)
        }
    }

    /// "~/project · ttys003".
    private var details: String {
        var parts: [String] = []
        if let cwd = row.cwd { parts.append((cwd as NSString).abbreviatingWithTildeInPath) }
        parts.append(row.tty.replacingOccurrences(of: "/dev/", with: ""))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var pill: some View {
        switch row.state {
        case .idle:
            if row.isGuarded { Pill(text: L10n.Popover.Sessions.pillGuarded, tint: .green) }
        case .waitingGuarded:
            Pill(text: L10n.Popover.Sessions.pillGuarded, tint: .green)
        case .waitingNotGuarded, .settled:
            Pill(text: L10n.Popover.Sessions.pillWaiting, tint: .orange)
        case .confirming:
            Pill(text: L10n.Popover.Sessions.pillSending, tint: .gray)
        case .unconfirmed:
            Pill(text: L10n.Popover.Sessions.pillNotSent, tint: .orange)
        case .ambiguous:
            Pill(text: L10n.Popover.Sessions.pillUnclear, tint: .gray)
        }
    }

    /// The one-line hint, with the button that continues by hand where there is one.
    @ViewBuilder private var detail: some View {
        switch row.state {
        case .idle:
            EmptyView()
        case .waitingGuarded:
            switch SessionsPresentation.note(state: row.state, paused: paused, autoContinue: autoContinue) {
            case .pausedResumeContinues: hint(L10n.Popover.Sessions.pausedResume)
            case .autoContinueOff: hint(L10n.Popover.Sessions.autoContinueOff)
            default: hint(L10n.Popover.Sessions.waitingGuarded)
            }
        case .waitingNotGuarded:
            byHand(L10n.Popover.Sessions.waitingNotGuarded, button: L10n.Popover.Sessions.continueNow)
        case .confirming:
            hint(L10n.Popover.Sessions.confirming)
        case .unconfirmed:
            byHand(L10n.Popover.Sessions.unconfirmed, button: L10n.Popover.Sessions.sendAgain)
        case .settled:
            byHand(L10n.Popover.Sessions.settled, button: L10n.Popover.Sessions.continueNow)
        case .ambiguous:
            hint(L10n.Popover.Sessions.ambiguous)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A state that needs the owner, with the button that continues the mapped thread by hand
    /// (`Engine.continueNow`, which also sends an unconfirmed continue again with the same message id).
    private func byHand(_ text: String, button: String) -> some View {
        HStack(spacing: PanelMetrics.s) {
            hint(text)
            Spacer(minLength: PanelMetrics.xs)
            if let threadId = row.threadId {
                if model.continuing.contains(threadId) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(button) { model.continueNow(threadId: threadId) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .lineLimit(1)
                        .fixedSize()
                        .disabled(!canContinue)
                        .help(canContinue ? "" : L10n.Popover.Sessions.continueNeedsLimit)
                        .accessibilityLabel("\(button): \(row.title)")
                }
            }
        }
    }
}
