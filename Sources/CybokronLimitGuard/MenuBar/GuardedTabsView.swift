import Foundation
import LimitGuardCore
import SwiftUI

/// "Codex sessions" (spec §7.3 "Guarded tabs", D19): every Terminal tab running Codex with a
/// checkbox; an unticked waiting tab offers Continue now, an unclear one says to continue by hand.
struct GuardedTabsView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var model: PopoverModel
    let isReadOnly: Bool
    let palette: PanelPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.Popover.Sessions.title, palette: palette)
            let rows = SessionsPresentation.rows(tabs: engine.tabs, sessions: engine.sessions, snapshot: engine.snapshot, now: Date())
            if rows.isEmpty {
                Text(L10n.Popover.Sessions.none)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            } else {
                ForEach(rows) { row in
                    SessionRowView(
                        row: row, model: model, palette: palette,
                        canContinue: !isReadOnly && engine.snapshot?.ordinaryUsageAllowed == true,
                        setGuarded: { engine.setGuarded(row.ref, $0) })
                }
                Text(L10n.Popover.Sessions.guardHelp)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    @ObservedObject var model: PopoverModel
    let palette: PanelPalette
    let canContinue: Bool
    let setGuarded: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { row.isGuarded }, set: setGuarded)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.primaryText)
                    Text(details)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            state
                .padding(.leading, 20)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.hairline))
    }

    /// "~/project · ttys003 · <thread title>", or "Thread 019a2b3c" without a title.
    private var details: String {
        var parts: [String] = []
        if let cwd = row.cwd { parts.append((cwd as NSString).abbreviatingWithTildeInPath) }
        parts.append(row.tty)
        if let title = row.threadTitle {
            parts.append(title)
        } else if let short = row.shortThreadId {
            parts.append(L10n.Popover.Sessions.thread(short))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var state: some View {
        switch row.state {
        case .idle:
            EmptyView()
        case .waitingGuarded:
            Label(L10n.Popover.Sessions.waitingGuarded, systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(PanelPalette.teal)
        case .waitingNotGuarded:
            HStack(spacing: 8) {
                Label(L10n.Popover.Sessions.waitingNotGuarded, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                Spacer(minLength: 4)
                if let threadId = row.threadId {
                    if model.continuing.contains(threadId) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L10n.Popover.Sessions.continueNow) { model.continueNow(threadId: threadId) }
                            .controlSize(.small)
                            .disabled(!canContinue)
                            .help(canContinue ? "" : L10n.Popover.Sessions.continueNeedsLimit)
                    }
                }
            }
        case .ambiguous:
            Label(L10n.Popover.Sessions.ambiguous, systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
