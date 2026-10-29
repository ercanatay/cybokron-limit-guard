import Foundation

/// The Engine's time source. Not named `Clock` so it does not shadow the standard library protocol.
public protocol EngineClock: Sendable {
    var now: Date { get }
    /// Returns at `date` or later; throws when the task is cancelled.
    func sleep(until date: Date) async throws
}

/// Wall-clock time. The sleep runs on `ContinuousClock`, which keeps counting while the Mac sleeps,
/// so a deadline that passed during sleep fires right after wake.
public struct SystemClock: EngineClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(until date: Date) async throws {
        let seconds = date.timeIntervalSinceNow
        if seconds > 0 {
            try await Task.sleep(for: .milliseconds(Int64((seconds * 1000).rounded(.up))))
        } else {
            try Task.checkCancellation()
        }
    }
}
