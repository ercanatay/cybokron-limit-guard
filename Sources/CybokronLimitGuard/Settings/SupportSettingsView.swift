import SwiftUI

/// Settings → Support: the About window's content (`AboutContentView`) — ways to support the
/// project, social profiles, the app's links, books and other projects — in a scrolling pane as
/// wide as the other panes, on the same background as the About window.
struct SupportSettingsView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            AboutContentView()
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
        }
        .frame(width: 480)
        .background(PanelPalette.forScheme(scheme).solidBackground)
    }
}
