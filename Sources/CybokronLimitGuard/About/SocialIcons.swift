import LimitGuardCore
import SwiftUI

/// Single-color brand glyphs for the About window's social row, drawn from the SVG path data in
/// `SocialIconPaths` (compiled into the app, so they need no bundle resources).
@MainActor
enum SocialIcons {
    /// Profile id → parsed glyph, parsed once.
    private static let paths: [String: Path] = SocialIconPaths.all.compactMapValues { data in
        SVGPathData.path(from: data).map(Path.init)
    }

    /// The glyph shape for a profile id (scales to whatever frame it is given), or `nil` when the
    /// profile has no glyph or its path data doesn't parse.
    static func shape(for id: String) -> SVGPathShape? {
        paths[id].map { SVGPathShape(glyph: $0) }
    }

    /// Whether the profile has path data at all (Ekşi Sözlük, not in Simple Icons, has none).
    static func hasPathData(for id: String) -> Bool {
        SocialIconPaths.all[id] != nil
    }
}

/// Fills a path drawn in the 24×24 viewBox of `SocialIconPaths` into whatever rect it is given.
struct SVGPathShape: Shape {
    let glyph: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / SocialIconPaths.viewBoxSize
        return glyph
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
