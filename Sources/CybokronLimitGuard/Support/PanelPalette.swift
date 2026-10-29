import AppKit
import SwiftUI

/// Colors of the About window and the settings panes: deep slate surfaces with teal and indigo accents, dark first.
struct PanelPalette {
    /// Primary accent: Open All, running indicators, hover.
    static let teal = Color(.sRGB, red: 0.17, green: 0.77, blue: 0.71)
    /// Secondary accent: Close All.
    static let indigo = Color(.sRGB, red: 0.40, green: 0.42, blue: 0.96)
    /// Force Quit, shown while ⌘ is held.
    static let warning = Color(.sRGB, red: 0.95, green: 0.42, blue: 0.38)

    /// Background without frosted glass.
    let solidBackground: Color
    /// Wash over the frosted glass, so the blur picks up the palette.
    let glassTint: Color
    let primaryText: Color
    let secondaryText: Color
    let hairline: Color
    let hover: Color
    let pressed: Color
    /// Outline of the panel, an AppKit color because it's drawn by the panel's layer.
    let border: NSColor

    static func forScheme(_ scheme: ColorScheme) -> PanelPalette {
        scheme == .dark ? dark : light
    }

    static let dark = PanelPalette(
        solidBackground: Color(.sRGB, red: 0.071, green: 0.090, blue: 0.125),
        glassTint: Color(.sRGB, red: 0.10, green: 0.11, blue: 0.24).opacity(0.28),
        primaryText: Color.white.opacity(0.94),
        secondaryText: Color.white.opacity(0.58),
        hairline: Color.white.opacity(0.08),
        hover: teal.opacity(0.20),
        pressed: teal.opacity(0.32),
        border: NSColor.white.withAlphaComponent(0.10)
    )

    static let light = PanelPalette(
        solidBackground: Color(.sRGB, red: 0.953, green: 0.961, blue: 0.976),
        glassTint: Color(.sRGB, red: 0.86, green: 0.95, blue: 0.94).opacity(0.22),
        primaryText: Color(.sRGB, red: 0.07, green: 0.09, blue: 0.12),
        secondaryText: Color.black.opacity(0.52),
        hairline: Color.black.opacity(0.08),
        hover: teal.opacity(0.16),
        pressed: teal.opacity(0.28),
        border: NSColor.black.withAlphaComponent(0.10)
    )
}
