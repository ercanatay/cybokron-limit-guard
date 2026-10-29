import LimitGuardCore
import SwiftUI

/// Continue: auto-continue and its limits, the language → text table and the fallback text.
struct ContinueSettingsView: View {
    @ObservedObject var model: SettingsModel

    @State private var newCode = ""
    @State private var newText = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsStatusBanner(model: model)
            Form {
                Section {
                    Toggle(L10n.Settings.Continue.autoContinue, isOn: model.binding(\.autoContinue))
                    Stepper(
                        L10n.Settings.Continue.countdown(model.settings.countdownSeconds),
                        value: model.binding(\.countdownSeconds),
                        in: SettingsLimits.countdownSeconds
                    )
                    Stepper(
                        L10n.Settings.Continue.maxTries(model.settings.maxContinues),
                        value: model.binding(\.maxContinues),
                        in: SettingsLimits.maxContinues
                    )
                    Stepper(
                        L10n.Settings.Continue.minGap(model.settings.minGapMinutes),
                        value: Binding(
                            get: { model.settings.minGapMinutes },
                            set: { value in model.mutate { $0.minGapMinutes = value } }
                        ),
                        in: SettingsLimits.minGapMinutes
                    )
                }

                Section {
                    ForEach(model.settings.continueTexts.keys.sorted(), id: \.self) { code in
                        row(code: code)
                    }
                    addRow
                } header: {
                    Text(L10n.Settings.Continue.textsHeader)
                } footer: {
                    Text(L10n.Settings.Continue.textsFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    CommitTextField(
                        L10n.Settings.Continue.fallback,
                        value: model.settings.fallbackText,
                        commit: { text in
                            model.mutate { $0.fallbackText = SettingsLimits.appliedFallbackText(text, previous: $0.fallbackText) }
                            return model.settings.fallbackText
                        }
                    )
                }
            }
            .formStyle(.grouped)
            .disabled(model.isReadOnly)
        }
        .frame(width: 480)
    }

    private func row(code: String) -> some View {
        HStack {
            Text(code)
                .font(.body.monospaced())
                .frame(width: 48, alignment: .leading)
            CommitTextField(
                L10n.Settings.Continue.text,
                value: model.settings.continueTexts[code] ?? "",
                commit: { text in
                    model.mutate { SettingsLimits.applyContinueText(text, for: code, to: &$0.continueTexts) }
                    return model.settings.continueTexts[code] ?? text
                }
            )
            Button {
                model.mutate { $0.continueTexts[code] = nil }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.Settings.Continue.remove(code))
            .accessibilityLabel(L10n.Settings.Continue.remove(code))
        }
    }

    private var addRow: some View {
        HStack {
            TextField(L10n.Settings.Continue.languageCode, text: $newCode)
                .frame(width: 96)
            TextField(L10n.Settings.Continue.text, text: $newText)
            Button(L10n.Settings.Continue.add, action: add)
                .disabled(!canAdd)
        }
        .onSubmit { if canAdd { add() } }
    }

    private var normalizedNewCode: String? { ContinueTextTable.normalizedCode(newCode) }

    private var canAdd: Bool {
        guard let code = normalizedNewCode else { return false }
        return !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.settings.continueTexts[code] == nil
    }

    private func add() {
        guard let code = normalizedNewCode else { return }
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.mutate { $0.continueTexts[code] = text }
        newCode = ""
        newText = ""
    }
}
