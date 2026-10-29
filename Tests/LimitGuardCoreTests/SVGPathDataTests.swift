import CoreGraphics
import Foundation
import Testing
@testable import LimitGuardCore

struct SVGPathDataTests {
    private func box(_ data: String) -> CGRect? {
        SVGPathData.path(from: data)?.boundingBoxOfPath
    }

    private func isClose(_ a: CGRect?, _ b: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test func absoluteLinesAndClose() {
        #expect(isClose(box("M0 0L10 0L10 10Z"), CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    @Test func relativeCommandsAndHorizontalVertical() {
        #expect(isClose(box("m2 3h4v5h-4z"), CGRect(x: 2, y: 3, width: 4, height: 5)))
        #expect(isClose(box("M2 3H6V8H2Z"), CGRect(x: 2, y: 3, width: 4, height: 5)))
    }

    @Test func compactNumbersSplitOnSignsAndSecondDots() {
        // ".5.5" is two numbers; "-1-1" too.
        #expect(isClose(box("M.5.5l1-1l-1-1z"), CGRect(x: 0.5, y: -1.5, width: 1, height: 2)))
        #expect(isClose(box("M1e1,0 L2E+1 1e0"), CGRect(x: 10, y: 0, width: 10, height: 1)))
    }

    @Test func implicitLinetosAfterMoveto() {
        #expect(isClose(box("M0 0 4 0 4 4"), CGRect(x: 0, y: 0, width: 4, height: 4)))
        #expect(isClose(box("m1 1 2 0 0 2"), CGRect(x: 1, y: 1, width: 2, height: 2)))
    }

    @Test func relativeMovetoAfterCloseStartsFromSubpathStart() {
        // After z the current point is back at (10, 10); m2 2 moves to (12, 12).
        #expect(isClose(box("M10 10h5v5zm2 2h1v1z"), CGRect(x: 10, y: 10, width: 5, height: 5)))
        #expect(isClose(box("M10 10h5v5zm-2-2h1v1z"), CGRect(x: 8, y: 8, width: 7, height: 7)))
    }

    @Test func arcsWithCompactFlags() {
        // A half circle of radius 5 from (0, 5) to (10, 5) bulging up (sweep 1 in y-down space).
        let up = box("M0 5a5 5 0 0 1 10 0")
        #expect(isClose(up, CGRect(x: 0, y: 0, width: 10, height: 5), tolerance: 0.01))
        // Same arc with flags written without separators.
        #expect(isClose(box("M0 5a5 5 0 0110 0"), CGRect(x: 0, y: 0, width: 10, height: 5), tolerance: 0.01))
        // The other sweep bulges down.
        #expect(isClose(box("M0 5A5 5 0 0 0 10 5"), CGRect(x: 0, y: 5, width: 10, height: 5), tolerance: 0.01))
    }

    @Test func arcWithTooSmallRadiiIsScaledUp() {
        // Radius 1 can't span 10 points; it is scaled to 5, a half circle.
        #expect(isClose(box("M0 5A1 1 0 0 1 10 5"), CGRect(x: 0, y: 0, width: 10, height: 5), tolerance: 0.01))
    }

    @Test func curvesStayWithinTheirControlHull() {
        let cubic = box("M0 0C0 10 10 10 10 0S20-10 20 0")
        #expect(cubic.map { $0.minX >= -0.001 && $0.maxX <= 20.001 && $0.height > 10 } == true)
        let quad = box("M0 0Q5 10 10 0T20 0")
        #expect(quad.map { $0.minY < -4 && $0.maxY > 4 && abs($0.width - 20) < 0.001 } == true)
    }

    @Test func malformedDataIsRejected() {
        #expect(SVGPathData.path(from: "") == nil)
        #expect(SVGPathData.path(from: "   ") == nil)
        #expect(SVGPathData.path(from: "L1 1") == nil)  // must start with a moveto
        #expect(SVGPathData.path(from: "M0 0L1") == nil)  // missing coordinate
        #expect(SVGPathData.path(from: "M0 0z 1 1") == nil)  // numbers after z
        #expect(SVGPathData.path(from: "M0 0X1 1") == nil)  // unknown command
        #expect(SVGPathData.path(from: "M0 0A1 1 0 2 0 1 1") == nil)  // flag must be 0 or 1
    }

    /// SwiftUI's `Path(String)` returns `nil` for SVG path data, which left the About window's
    /// social buttons empty; every glyph must parse with this parser instead.
    @Test func everySocialGlyphParsesInsideItsViewBox() throws {
        let slack = 0.5
        for (id, data) in SocialIconPaths.all {
            let path = try #require(SVGPathData.path(from: data), "\(id)")
            let box = path.boundingBoxOfPath
            #expect(box.width > 10 && box.height > 5, "\(id): \(box)")
            #expect(box.minX >= -slack && box.minY >= -slack, "\(id): \(box)")
            #expect(box.maxX <= SocialIconPaths.viewBoxSize + slack && box.maxY <= SocialIconPaths.viewBoxSize + slack,
                    "\(id): \(box)")
        }
    }

    @Test func everyProfileButEksiSozlukHasAGlyph() {
        let withoutGlyph = SocialProfile.all.filter { SocialIconPaths.all[$0.id] == nil }.map(\.id)
        #expect(withoutGlyph == ["eksisozluk"])
        #expect(Set(SocialIconPaths.all.keys).isSubset(of: Set(SocialProfile.all.map(\.id))))
    }
}
