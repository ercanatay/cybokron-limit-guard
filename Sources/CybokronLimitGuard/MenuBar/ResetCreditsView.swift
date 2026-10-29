import Foundation
import LimitGuardCore
import SwiftUI

/// "Usage limit resets" (spec §4.2 item 5, D3): an "N available" chip and one row per credit with
/// its backend title, expiry and a Use Reset button for an available credit.
struct ResetCreditsView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var model: PopoverModel
    let isReadOnly: Bool
    let palette: PanelPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.Popover.Resets.title, palette: palette) {
                if let snapshot = engine.snapshot {
                    Text(L10n.Popover.Resets.available(snapshot.availableCreditCount))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(PanelPalette.teal.opacity(0.18)))
                        .foregroundStyle(palette.primaryText)
                }
            }
            if let snapshot = engine.snapshot {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let rows = CreditPresentation.rows(credits: snapshot.credits, now: context.date)
                    let listed = Set(rows.map(\.id))
                    // A used credit can drop out of the list after the re-read; its result stays visible here.
                    ForEach(model.creditResults.keys.filter { !listed.contains($0) }.sorted(), id: \.self) { id in
                        if let feedback = model.creditResults[id] {
                            FeedbackText(feedback: feedback, palette: palette)
                        }
                    }
                    if rows.isEmpty {
                        Text(L10n.Popover.Resets.none)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rows) { row in
                                CreditRowView(row: row, model: model, isReadOnly: isReadOnly, palette: palette)
                            }
                        }
                    }
                }
                if isReadOnly, !snapshot.availableCredits.isEmpty {
                    Text(L10n.Popover.Resets.readOnlyHint)
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
    }
}

private struct CreditRowView: View {
    let row: CreditRow
    @ObservedObject var model: PopoverModel
    let isReadOnly: Bool
    let palette: PanelPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title ?? L10n.Popover.Resets.untitled)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    expiry
                }
                Spacer(minLength: 6)
                trailing
            }
            if model.spendingCreditId == row.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Popover.Resets.inFlight).font(.caption).foregroundStyle(palette.secondaryText)
                }
            } else if let feedback = model.creditResults[row.id] {
                FeedbackText(feedback: feedback, palette: palette)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(row.isExpiringSoon ? Color.orange.opacity(0.14) : palette.hairline))
    }

    @ViewBuilder private var expiry: some View {
        if let date = row.expiryText, let zone = row.timeZoneLabel {
            let day = row.expiryDay.map { $0 == .today ? L10n.Popover.Resets.expiresToday : L10n.Popover.Resets.expiresTomorrow }
            Text([L10n.Popover.Resets.expires(date, zone), day].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.isExpiringSoon ? Color.orange : palette.secondaryText)
        } else {
            Text(L10n.Popover.Resets.neverExpires)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.status {
        case .available:
            Button(L10n.Popover.Resets.use) { model.useReset(row) }
                .controlSize(.small)
                .disabled(isReadOnly || model.spendingCreditId != nil)
        case .redeeming:
            Text(L10n.Popover.Resets.redeeming).font(.caption).foregroundStyle(palette.secondaryText)
        case .redeemed:
            Text(L10n.Popover.Resets.redeemed).font(.caption).foregroundStyle(palette.secondaryText)
        case let .unknown(status):
            // An unknown status is never offered for spending; the backend's word is shown as is.
            Text(status).font(.caption).foregroundStyle(palette.secondaryText)
        }
    }
}

/// The inline text after Use Reset.
private struct FeedbackText: View {
    let feedback: CreditFeedback
    let palette: PanelPalette

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        switch feedback {
        case let .spent(result): return L10n.Popover.Resets.result(result)
        case .noLongerAvailable: return L10n.Popover.Resets.noLongerAvailable
        }
    }

    private var tint: Color {
        switch feedback {
        case .spent(.outcome(.reset)): return PanelPalette.teal
        case .spent(.outcome): return palette.primaryText
        case .spent(.unknown), .spent(.busy), .noLongerAvailable: return .orange
        }
    }
}
