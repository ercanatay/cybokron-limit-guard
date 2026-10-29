import Foundation
import LimitGuardCore
import SwiftUI

/// What the Engine does next on its own, with Cancel for a continue (spec §4.2 item 4). The
/// countdown's seconds tick live.
struct NextActionView: View {
    let action: NextAction
    let tabs: [EngineTab]
    let palette: PanelPalette
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.s) {
            SectionHeader(title: L10n.Popover.Next.title, palette: palette)
            PanelCard(palette: palette, tint: PanelPalette.teal) {
            HStack(alignment: .center, spacing: PanelMetrics.s) {
                switch action.kind {
                case let .continueAt(date, threadId, text):
                    line(L10n.Popover.Next.continueAt(PopoverFormat.date(date, template: Calendar.current.isDateInToday(date) ? "jmm" : "EEEjmm"), text, target(threadId)),
                         symbol: "clock")
                    cancelButton
                case let .countdown(until, threadId, text):
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                        line(L10n.Popover.Next.countdown(text, seconds, target(threadId)), symbol: "timer")
                    }
                    cancelButton
                case let .autoSpendArmed(threshold):
                    line(L10n.Popover.Next.autoSpend(PopoverFormat.percent(Double(threshold))), symbol: "arrow.counterclockwise.circle")
                }
            }
            }
        }
    }

    private var cancelButton: some View {
        Button(L10n.Common.cancel, action: cancel)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func line(_ text: String, symbol: String) -> some View {
        Label {
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: symbol).foregroundStyle(PanelPalette.teal)
        }
    }

    /// "~/project (ttys003)" for the tab the thread is mapped to.
    private func target(_ threadId: String) -> String {
        guard let tab = tabs.first(where: { $0.threadId == threadId })?.tab else {
            return L10n.Popover.Next.unknownTarget
        }
        let folder = tab.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? tab.title
        return "\(folder) (\(tab.ref.tty))"
    }
}
