import SwiftUI

/// The notice above a pane's form while the settings file can't be changed or saved.
struct SettingsStatusBanner: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let reason = model.readOnlyReason {
            banner(reason == .newerSchema ? L10n.Settings.readOnlyNewer : L10n.Settings.readOnlyUnreadable)
        } else if model.saveFailed {
            banner(L10n.Settings.saveFailed)
        }
    }

    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
    }
}

/// A text field that commits its value when Return is pressed or focus leaves it, so half-typed
/// text never reaches the settings file.
struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(_ title: String, value: String, commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft)
            .focused($isFocused)
            .onSubmit { commit(draft) }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit(draft) }
            }
            .onChange(of: value) { _, newValue in
                if !isFocused { draft = newValue }
            }
            .onDisappear { commit(draft) }
    }
}
