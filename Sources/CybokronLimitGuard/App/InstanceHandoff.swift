import AppKit
import LimitGuardCore
import OSLog

/// Runs this copy of the app as a second copy (see `InstanceHandoff` in LimitGuardCore for why
/// there can be two): it sets nothing up, hands the `cybokronlimitguard://` URLs it was opened with
/// to the older copy that runs, or without any opens that copy (which then shows its popover), and
/// quits. There must be only one reset ledger and one executor per user session.
@MainActor
final class SecondCopyHandoff {
    private static let logger = Logger(subsystem: "com.cybokron.limitguard", category: "handoff")

    private let primary: NSRunningApplication
    private let primaryURL: URL
    private var handoffsInFlight = 0

    /// A handoff to the older copy that runs, or nil when this copy is the oldest. A copy that is just
    /// quitting (restart after a language change or an update) gets up to 3 s to go first.
    static func toOlderRunningCopy() -> SecondCopyHandoff? {
        for _ in 0..<30 where olderCopy() != nil { Thread.sleep(forTimeInterval: 0.1) }
        guard let (primary, url) = olderCopy() else { return nil }
        return SecondCopyHandoff(primary: primary, primaryURL: url)
    }

    private static func olderCopy() -> (NSRunningApplication, URL)? {
        let current = NSRunningApplication.current
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier && $0.bundleURL != nil }
        guard let oldest = InstanceHandoff.primary(among: others.map(instance), current: instance(current)),
              let primary = others.first(where: { $0.processIdentifier == oldest.processIdentifier }),
              let url = primary.bundleURL
        else { return nil }
        return (primary, url)
    }

    private static func instance(_ application: NSRunningApplication) -> InstanceHandoff.Instance {
        InstanceHandoff.Instance(processIdentifier: application.processIdentifier, launchDate: application.launchDate)
    }

    private init(primary: NSRunningApplication, primaryURL: URL) {
        self.primary = primary
        self.primaryURL = primaryURL
        Self.logger.notice("Another copy runs (pid \(primary.processIdentifier) at \(primaryURL.path, privacy: .public)); this copy hands over to it and quits")
    }

    /// Hands `urls` to the older copy, or with none, opens it; quits once that is done.
    func handOff(_ urls: [URL]) {
        handoffsInFlight += 1
        NSApp.yieldActivation(to: primary)
        let configuration = NSWorkspace.OpenConfiguration()
        // Exactly the older copy: LaunchServices must not pick another running copy, this one included.
        configuration.allowsRunningApplicationSubstitution = false
        let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [weak self] _, error in
            let failure = error.map { String(describing: $0) }
            Task { @MainActor [weak self] in self?.finished(failure: failure) }
        }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: primaryURL, configuration: configuration, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: primaryURL, configuration: configuration, completionHandler: completion)
        }
    }

    private func finished(failure: String?) {
        handoffsInFlight -= 1
        if let failure {
            Self.logger.error("Handing over to the other copy failed: \(failure, privacy: .public)")
        }
        if handoffsInFlight == 0 { NSApp.terminate(nil) }
    }
}
