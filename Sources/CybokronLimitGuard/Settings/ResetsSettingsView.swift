import LimitGuardCore
import SwiftUI

/// Resets: whether the app may spend a reset credit by itself, at which weekly usage, and the
/// expiry reminders.
struct ResetsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsStatusBanner(model: model)
            Form {
                Section {
                    Toggle(L10n.Settings.Resets.autoUse, isOn: model.binding(\.autoSpendEnabled))
                    Text(L10n.Settings.Resets.autoUseCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper(
                        L10n.Settings.Resets.threshold(model.settings.autoSpendThreshold),
                        value: model.binding(\.autoSpendThreshold),
                        in: SettingsLimits.autoSpendThreshold
                    )
                    .disabled(!model.settings.autoSpendEnabled)
                }
                Section {
                    Toggle(L10n.Settings.Resets.expiryReminders, isOn: model.binding(\.expiryReminders))
                }
            }
            .formStyle(.grouped)
            .disabled(model.isReadOnly)
        }
        .frame(width: 480)
    }
}
