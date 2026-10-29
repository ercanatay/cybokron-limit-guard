import SwiftUI

/// Notifications: one switch per kind.
struct NotificationsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsStatusBanner(model: model)
            Form {
                Section {
                    Toggle(L10n.Settings.Notifications.limitReached, isOn: model.notifyBinding(\.limitReached))
                    Toggle(L10n.Settings.Notifications.limitIsBack, isOn: model.notifyBinding(\.limitIsBack))
                    Toggle(L10n.Settings.Notifications.continueSent, isOn: model.notifyBinding(\.continueSent))
                    Toggle(L10n.Settings.Notifications.continueSkipped, isOn: model.notifyBinding(\.continueSkipped))
                    Toggle(L10n.Settings.Notifications.resetUsed, isOn: model.notifyBinding(\.resetUsed))
                    Toggle(L10n.Settings.Notifications.resetExpiring, isOn: model.notifyBinding(\.resetExpiring))
                    Toggle(L10n.Settings.Notifications.readOnly, isOn: model.notifyBinding(\.readOnly))
                    Toggle(L10n.Settings.Notifications.permissionMissing, isOn: model.notifyBinding(\.permissionMissing))
                } header: {
                    Text(L10n.Settings.Notifications.header)
                }
            }
            .formStyle(.grouped)
            .disabled(model.isReadOnly)
        }
        .frame(width: 480)
    }
}
