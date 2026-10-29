import Foundation

/// Sizing rules for the menu-bar popover.
public enum PopoverLayout {
    public static let minimumContentHeight: CGFloat = 300
    public static let screenMargin: CGFloat = 160
    /// The scrolling part never grows beyond this; the footer is extra, below it.
    public static let maximumContentHeight: CGFloat = 520

    /// The tallest the scrolling part of the popover may be: `maximumContentHeight`, or on a small
    /// screen its visible height less room for the menu bar, the arrow and the footer, but never
    /// below `minimumContentHeight`.
    public static func maxContentHeight(visibleScreenHeight: CGFloat) -> CGFloat {
        min(maximumContentHeight, max(minimumContentHeight, visibleScreenHeight - screenMargin))
    }
}
