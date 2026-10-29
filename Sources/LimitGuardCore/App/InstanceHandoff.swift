import Foundation

/// Keeps the main app to one running copy.
///
/// The app can sit at several paths at once: in Applications, on its mounted disk image, in a build
/// folder. To open a `cybokronlimitguard:` URL, LaunchServices picks one of these copies by its own
/// ranking, not necessarily the one that runs, and launches it next to the running one. That second
/// copy would show the popover in a process of its own, with a second menu-bar item, while
/// the copy the user works with gets nothing. So a copy that finds an older copy running hands its
/// requests to that copy and quits.
public enum InstanceHandoff {
    /// A running copy of the main app.
    public struct Instance: Equatable, Sendable {
        public let processIdentifier: Int32
        /// When LaunchServices launched it; `nil` for a copy started some other way, such as its
        /// executable run from a terminal.
        public let launchDate: Date?

        public init(processIdentifier: Int32, launchDate: Date?) {
            self.processIdentifier = processIdentifier
            self.launchDate = launchDate
        }
    }

    /// The copy `current` should hand its requests to: the oldest of `others`, if it started before
    /// `current`. `nil` when `current` is the oldest copy, which keeps running.
    ///
    /// Copies are ordered by launch date, then by process ID; a copy without a launch date (run from a
    /// terminal) counts as the newest, so it hands over to a copy that runs rather than starting a
    /// second Engine on the same reset ledger. That's a total order, so of copies starting at the
    /// same time exactly one stays.
    public static func primary(among others: [Instance], current: Instance) -> Instance? {
        others
            .filter { $0.processIdentifier != current.processIdentifier && startedBefore($0, current) }
            .min(by: startedBefore)
    }

    static func startedBefore(_ first: Instance, _ second: Instance) -> Bool {
        let firstDate = first.launchDate ?? .distantFuture
        let secondDate = second.launchDate ?? .distantFuture
        if firstDate != secondDate {
            return firstDate < secondDate
        }
        return first.processIdentifier < second.processIdentifier
    }
}
