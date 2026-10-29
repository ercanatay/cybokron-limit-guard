import AppKit
import LimitGuardCore
import SwiftUI

/// The activity log in a table, newest first, with Copy (tab-separated) and Clear.
@MainActor
final class ActivityWindowController: NSWindowController {
    private let model: ActivityModel

    /// `load` returns the stored entries (oldest first); `clear` empties the log.
    init(load: @escaping () -> [ActivityEntry], clear: @escaping () -> Void) {
        let model = ActivityModel(load: load, clear: clear)
        self.model = model
        let hostingController = NSHostingController(rootView: ActivityView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.Activity.title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 420))
        window.contentMinSize = NSSize(width: 560, height: 260)
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        model.reload()
        if let window, !window.isVisible { window.center() }
        bringToFront()
    }
}

@MainActor
private final class ActivityModel: ObservableObject {
    @Published var rows: [ActivityRow] = []
    private let load: () -> [ActivityEntry]
    private let clearLog: () -> Void

    init(load: @escaping () -> [ActivityEntry], clear: @escaping () -> Void) {
        self.load = load
        self.clearLog = clear
    }

    func reload() {
        rows = load().reversed().enumerated().map { ActivityRow(id: $0.offset, entry: $0.element) }
    }

    func clear() {
        clearLog()
        reload()
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.map(\.tabSeparated).joined(separator: "\n"), forType: .string)
    }

    /// Asks first; the log can't be brought back.
    func confirmClear() {
        let alert = NSAlert()
        alert.messageText = L10n.Activity.clearTitle
        alert.informativeText = L10n.Activity.clearBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Activity.clearConfirm)
        alert.addButton(withTitle: L10n.Common.cancel)
        if alert.runModal() == .alertFirstButtonReturn { clear() }
    }
}

private struct ActivityRow: Identifiable {
    let id: Int
    let entry: ActivityEntry

    var time: String { Self.timeFormatter.string(from: entry.date) }
    var kind: String { L10n.Activity.kindLabel(entry.kind) }
    var tab: String { entry.tab ?? "" }
    /// First 8 characters of the thread id.
    var thread: String { String((entry.threadId ?? "").prefix(8)) }
    var text: String { entry.text ?? "" }
    var detail: String { entry.detail ?? "" }

    var tabSeparated: String {
        [time, kind, tab, thread, text, detail]
            .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

private struct ActivityView: View {
    @ObservedObject var model: ActivityModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette.forScheme(scheme)
        VStack(spacing: 0) {
            Table(model.rows) {
                TableColumn(L10n.Activity.time) { Text($0.time).monospacedDigit() }.width(min: 120, ideal: 140)
                TableColumn(L10n.Activity.kind) { Text($0.kind) }.width(min: 110, ideal: 150)
                TableColumn(L10n.Activity.tab) { Text($0.tab) }.width(min: 40, ideal: 70)
                TableColumn(L10n.Activity.thread) { Text($0.thread).monospaced() }.width(min: 60, ideal: 80)
                TableColumn(L10n.Activity.text) { Text($0.text) }
                TableColumn(L10n.Activity.detail) { Text($0.detail).foregroundStyle(palette.secondaryText) }
            }
            .overlay {
                if model.rows.isEmpty {
                    Text(L10n.Activity.empty).foregroundStyle(palette.secondaryText)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.Activity.copy) { model.copyAll() }.disabled(model.rows.isEmpty)
                Button(L10n.Activity.clear) { model.confirmClear() }.disabled(model.rows.isEmpty)
            }
            .padding(12)
        }
        .background(palette.solidBackground)
    }
}
