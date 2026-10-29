import Foundation

/// Sizing rules for the menu-bar popover.
public enum PopoverLayout {
    public static let minimumContentHeight: CGFloat = 300
    public static let screenMargin: CGFloat = 160

    /// The tallest the scrolling part of the popover may be: the screen's visible height less room for
    /// the menu bar, the arrow and the footer, but never below `minimumContentHeight`.
    public static func maxContentHeight(visibleScreenHeight: CGFloat) -> CGFloat {
        max(minimumContentHeight, visibleScreenHeight - screenMargin)
    }
}
