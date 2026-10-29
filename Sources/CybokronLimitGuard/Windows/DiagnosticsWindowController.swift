import AppKit
import LimitGuardCore
import SwiftUI

/// Runs the diagnostics and lists the results with a button that copies the report.
@MainActor
final class DiagnosticsWindowController: NSWindowController {
    private let model = DiagnosticsModel()

    init() {
        let hostingController = NSHostingController(rootView: DiagnosticsView(model: model))
        hostingController.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.Diagnostics.title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window, brings the app to the front and runs the checks.
    func show() {
        NSApp.activate()
        if let window, !window.isVisible {
            window.layoutIfNeeded()
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.run()
    }
}

@MainActor
private final class DiagnosticsModel: ObservableObject {
    @Published var items: [DiagnosticItem] = []
    @Published var running = false

    func run() {
        guard !running else { return }
        running = true
        Task {
            let result = await Diagnostics.run()
            items = result
            running = false
        }
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticsCore.report(items, appVersion: AppInfo.version), forType: .string)
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Diagnostics.running)
                }
            }
            ForEach(model.items, id: \.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.status.symbol)
                        .foregroundStyle(color(item.status))
                        .frame(width: 18)
                        .accessibilityLabel(label(item.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        if let fix = item.fix {
                            Text(fix).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(L10n.Diagnostics.runAgain) { model.run() }.disabled(model.running)
                Button(L10n.Diagnostics.copyReport) { model.copyReport() }.disabled(model.items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func color(_ status: DiagnosticItem.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    private func label(_ status: DiagnosticItem.Status) -> String {
        switch status {
        case .ok: L10n.Diagnostics.statusOK
        case .warning: L10n.Diagnostics.statusWarning
        case .failed: L10n.Diagnostics.statusFailed
        }
    }
}
