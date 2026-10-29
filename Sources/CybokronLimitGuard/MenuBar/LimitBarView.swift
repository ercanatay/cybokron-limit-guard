import Foundation
import LimitGuardCore
import SwiftUI

/// One limit window: "5-hour limit", a bar, "100 % used · resets in 3 h 42 m (18:15)", and the
/// burn-rate forecast when it lies ahead (D28).
struct LimitBarView: View {
    let title: String
    let window: RateLimitWindow?
    let forecast: Date?
    let forecastText: (String) -> String
    /// The `DateFormatter` template of the reset time in brackets.
    let clockTemplate: String
    let palette: PanelPalette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: PanelMetrics.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    Spacer(minLength: PanelMetrics.s)
                    if let window {
                        Text(L10n.Popover.Limit.used(PopoverFormat.percent(window.usedPercent)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(palette.primaryText)
                    } else {
                        Text(L10n.Popover.Limit.notReported)
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                bar(fraction: (window?.usedPercent ?? 0) / 100)
                if let resetsAt = window?.resetsAt, resetsAt > context.date {
                    Text(L10n.Popover.Limit.resetsIn(
                        ResetsInFormatter.string(until: resetsAt, now: context.date, locale: PopoverFormat.appLocale),
                        PopoverFormat.date(resetsAt, template: clockTemplate)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                }
                if let forecast, forecast > context.date {
                    Text(forecastText(PopoverFormat.date(forecast, template: "EEEjmm")))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.hairline)
                Capsule()
                    .fill(PopoverFormat.tint(forUsed: window?.usedPercent ?? 0))
                    .frame(width: max(clamped > 0 ? 6 : 0, geometry.size.width * clamped))
            }
        }
        .frame(height: 6)
    }
}

/// Number and date formatting shared by the popover's views.
enum PopoverFormat {
    /// The language the app's strings are shown in, for `ResetsInFormatter`'s table.
    static var appLocale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// "100 %", in the system locale.
    static func percent(_ used: Double) -> String {
        (min(max(used, 0), 100) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// `date` in the system locale and time zone from a `DateFormatter` template.
    @MainActor
    static func date(_ date: Date, template: String) -> String {
        formatter(template).string(from: date)
    }

    @MainActor private static var formatters: [String: DateFormatter] = [:]

    /// One formatter per template, locale and time zone (a changed locale or zone gets new ones).
    @MainActor
    private static func formatter(_ template: String) -> DateFormatter {
        let key = "\(template)|\(Locale.current.identifier)|\(TimeZone.current.identifier)"
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter
    }

    /// Teal, orange from 80 %, red from 95 % (the menu-bar thresholds).
    static func tint(forUsed used: Double) -> Color {
        switch MenuBarText.level(usedPercent: used) {
        case .normal: return PanelPalette.teal
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
