import SwiftUI

/// The popover's spacing scale and card look, shared by every section.
enum PanelMetrics {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let cardRadius: CGFloat = 12
}

/// A rounded, hairline-bordered surface for a section's content.
struct PanelCard<Content: View>: View {
    let palette: PanelPalette
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(PanelMetrics.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
                    .fill(tint?.opacity(0.12) ?? palette.hairline.opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
                    .strokeBorder(tint?.opacity(0.35) ?? palette.hairline, lineWidth: 1))
    }
}

/// A small status pill ("Guarded", "expires today").
struct Pill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, PanelMetrics.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }
}
