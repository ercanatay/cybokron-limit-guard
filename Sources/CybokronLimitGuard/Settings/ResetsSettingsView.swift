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
                    HStack {
                        Text(L10n.Settings.Resets.threshold(model.settings.autoSpendThreshold))
                        Spacer(minLength: 8)
                        ThresholdField(value: model.binding(\.autoSpendThreshold))
                    }
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

/// A number field with a stepper beside it. Return or leaving the field commits the typed value,
/// clamped to the allowed range; text that is not a number reverts to the current value.
private struct ThresholdField: View {
    @Binding var value: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .accessibilityLabel(L10n.Settings.Resets.threshold(value))
            Text("%").foregroundStyle(.secondary)
            Stepper("", value: $value, in: SettingsLimits.autoSpendThreshold)
                .labelsHidden()
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, new in text = String(new) }
    }

    private func commit() {
        let digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        if let typed = Int(digits) {
            value = SettingsLimits.clamp(typed, to: SettingsLimits.autoSpendThreshold)
        }
        text = String(value)
    }
}
