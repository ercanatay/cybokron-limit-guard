import SwiftUI

/// The notice above a pane's form while the settings file can't be changed or saved.
struct SettingsStatusBanner: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let reason = model.readOnlyReason {
            banner(reason == .newerSchema ? L10n.Settings.readOnlyNewer : L10n.Settings.readOnlyUnreadable)
            if reason == .unreadable {
                Button(L10n.Settings.Reset.button) { model.resetUnreadable() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
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
    /// Stores the text and returns what was accepted, which the field then shows.
    let commit: (String) -> String

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(_ title: String, value: String, commit: @escaping (String) -> String) {
        self.title = title
        self.value = value
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft)
            .focused($isFocused)
            .onSubmit { draft = commit(draft) }
            .onChange(of: isFocused) { _, focused in
                if !focused { draft = commit(draft) }
            }
            .onChange(of: value) { _, newValue in
                if !isFocused { draft = newValue }
            }
            .onDisappear { _ = commit(draft) }
    }
}
