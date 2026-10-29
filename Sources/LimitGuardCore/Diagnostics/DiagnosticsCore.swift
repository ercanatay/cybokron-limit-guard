import Foundation

/// One line of the diagnostics report: what was checked, how it went and, if it needs attention, a one-line fix.
public struct DiagnosticItem: Equatable, Sendable {
    public enum ID: String, Sendable {
        case codexFound, appServer, signedIn, rateLimitsDecode, terminalAutomation, notifications, approvalPolicy, keepAwake
    }

    public enum Status: String, Sendable {
        case ok, warning, failed

        /// The mark shown in the window and the copied report.
        public var symbol: String {
            switch self {
            case .ok: "✓"
            case .warning: "⚠"
            case .failed: "✗"
            }
        }
    }

    public let id: ID
    public let title: String
    public let status: Status
    public let fix: String?

    public init(id: ID, title: String, status: Status, fix: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.fix = fix
    }
}

/// A macOS permission as far as it can be told without asking the user.
public enum PermissionState: Equatable, Sendable {
    case granted, denied, notDetermined
    /// Can't be checked now (Terminal isn't running).
    case unavailable
}

/// What the `account/rateLimits/read` probe found.
public enum LimitsProbe: Equatable, Sendable {
    /// Not tried: there is no codex to talk to.
    case notRun
    /// The app-server did not start or stopped answering.
    case unreachable(String)
    /// The server answered with an error, which is what a missing sign-in looks like.
    case rpcError(String)
    case read(ProtocolHealth)

    public init(error: Error) {
        if case let AppServerError.rpcError(_, message) = error {
            self = .rpcError(message)
        } else {
            self = .unreachable(String(describing: error))
        }
    }
}

/// The checks of the diagnostics window, as pure functions of values the app gathers: nothing here
/// touches the disk, the system or Codex, so every verdict can be tested.
public enum DiagnosticsCore {
    public struct Inputs: Sendable {
        public var codexVersion: String?
        public var codexFound: Bool
        /// The newest Codex version Limit Guard was tested against, e.g. "0.165.0".
        public var lastTestedCodexVersion: String?
        public var limits: LimitsProbe
        /// The text of `~/.codex/config.toml`, nil when it can't be read.
        public var configText: String?
        public var terminalAutomation: PermissionState
        public var notifications: PermissionState
        public var keepAwakeActive: Bool

        public init(
            codexVersion: String?, codexFound: Bool, lastTestedCodexVersion: String?, limits: LimitsProbe,
            configText: String?, terminalAutomation: PermissionState, notifications: PermissionState,
            keepAwakeActive: Bool
        ) {
            self.codexVersion = codexVersion
            self.codexFound = codexFound
            self.lastTestedCodexVersion = lastTestedCodexVersion
            self.limits = limits
            self.configText = configText
            self.terminalAutomation = terminalAutomation
            self.notifications = notifications
            self.keepAwakeActive = keepAwakeActive
        }
    }

    // MARK: - config.toml

    /// The top-level `approval_policy` of a Codex `config.toml`; keys inside `[sections]` don't count.
    public static func approvalPolicy(inConfig text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            guard line.hasPrefix("approval_policy") else { continue }
            let rest = line.dropFirst("approval_policy".count).drop { $0 == " " || $0 == "\t" }
            guard rest.first == "=" else { continue }
            let value = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard let quote = value.first, quote == "\"" || quote == "'" else { continue }
            let inner = value.dropFirst()
            guard let end = inner.firstIndex(of: quote) else { continue }
            return String(inner[..<end])
        }
        return nil
    }

    public static func approvalStatus(policy: String?) -> DiagnosticItem.Status {
        policy == "never" ? .ok : .warning
    }

    // MARK: - Items

    public static func items(_ inputs: Inputs) -> [DiagnosticItem] {
        [
            codexItem(inputs),
            appServerItem(inputs),
            signedInItem(inputs),
            decodeItem(inputs),
            terminalItem(inputs),
            notificationsItem(inputs),
            approvalItem(inputs),
            keepAwakeItem(inputs),
        ]
    }

    private static func codexItem(_ inputs: Inputs) -> DiagnosticItem {
        guard inputs.codexFound else {
            return DiagnosticItem(
                id: .codexFound,
                title: Localization.string("diagnostics.codex.missing", "Codex was not found"),
                status: .failed,
                fix: Localization.string("diagnostics.codex.missing.fix", "Install Codex or set its path in Settings → General."))
        }
        let version = inputs.codexVersion ?? Localization.string("diagnostics.codex.versionUnknown", "version unknown")
        if let tested = inputs.lastTestedCodexVersion.flatMap(SemanticVersion.init),
           let found = inputs.codexVersion.flatMap(numericVersion), found > tested {
            let testedText = tested.description
            return DiagnosticItem(
                id: .codexFound,
                title: Localization.format("diagnostics.codex.newer", "Codex found: %@, newer than the last tested version (%@)", version, testedText),
                status: .warning,
                fix: Localization.string("diagnostics.codex.newer.fix", "If something stops working, check for a Limit Guard update."))
        }
        return DiagnosticItem(
            id: .codexFound,
            title: Localization.format("diagnostics.codex.found", "Codex found: %@", version),
            status: .ok)
    }

    /// The first `x.y.z` in a `codex --version` line such as "codex-cli 0.165.0".
    static func numericVersion(_ text: String) -> SemanticVersion? {
        guard let range = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return SemanticVersion(String(text[range]))
    }

    private static func appServerItem(_ inputs: Inputs) -> DiagnosticItem {
        switch inputs.limits {
        case .read, .rpcError:
            return DiagnosticItem(
                id: .appServer,
                title: Localization.string("diagnostics.appServer.ok", "Codex app-server is reachable"),
                status: .ok)
        case .notRun:
            return DiagnosticItem(
                id: .appServer,
                title: Localization.string("diagnostics.appServer.notRun", "Codex app-server was not tried"),
                status: .failed,
                fix: Localization.string("diagnostics.appServer.notRun.fix", "Fix the Codex path first."))
        case .unreachable:
            return DiagnosticItem(
                id: .appServer,
                title: Localization.string("diagnostics.appServer.failed", "Codex app-server did not answer"),
                status: .failed,
                fix: Localization.string("diagnostics.appServer.failed.fix", "Update Codex, then run the check again."))
        }
    }

    private static func signedInItem(_ inputs: Inputs) -> DiagnosticItem {
        switch inputs.limits {
        case .read:
            return DiagnosticItem(
                id: .signedIn,
                title: Localization.string("diagnostics.signedIn.ok", "Signed in with ChatGPT"),
                status: .ok)
        case .rpcError:
            return DiagnosticItem(
                id: .signedIn,
                title: Localization.string("diagnostics.signedIn.failed", "Not signed in with ChatGPT"),
                status: .failed,
                fix: Localization.string("diagnostics.signedIn.failed.fix", "Run “codex login” in Terminal and sign in with ChatGPT."))
        case .notRun, .unreachable:
            return DiagnosticItem(
                id: .signedIn,
                title: Localization.string("diagnostics.signedIn.unknown", "Sign-in could not be checked"),
                status: .warning,
                fix: Localization.string("diagnostics.signedIn.unknown.fix", "Fix the checks above first."))
        }
    }

    private static func decodeItem(_ inputs: Inputs) -> DiagnosticItem {
        switch inputs.limits {
        case .read(.full):
            return DiagnosticItem(
                id: .rateLimitsDecode,
                title: Localization.string("diagnostics.decode.ok", "Usage limits are read correctly"),
                status: .ok)
        case .read(.readOnly):
            return DiagnosticItem(
                id: .rateLimitsDecode,
                title: Localization.string("diagnostics.decode.readOnly", "Codex changed how it reports usage"),
                status: .warning,
                fix: Localization.string("diagnostics.decode.readOnly.fix", "Automatic actions are paused until Limit Guard is updated."))
        case .notRun, .unreachable, .rpcError:
            return DiagnosticItem(
                id: .rateLimitsDecode,
                title: Localization.string("diagnostics.decode.unknown", "Usage limits could not be read"),
                status: .warning,
                fix: Localization.string("diagnostics.decode.unknown.fix", "Fix the checks above first."))
        }
    }

    private static func terminalItem(_ inputs: Inputs) -> DiagnosticItem {
        let fix = Localization.string(
            "diagnostics.terminal.fix", "Allow Cybokron Limit Guard under System Settings → Privacy & Security → Automation → Terminal.")
        switch inputs.terminalAutomation {
        case .granted:
            return DiagnosticItem(
                id: .terminalAutomation,
                title: Localization.string("diagnostics.terminal.ok", "Terminal automation is allowed"),
                status: .ok)
        case .denied:
            return DiagnosticItem(
                id: .terminalAutomation,
                title: Localization.string("diagnostics.terminal.denied", "Terminal automation is not allowed"),
                status: .failed, fix: fix)
        case .notDetermined:
            return DiagnosticItem(
                id: .terminalAutomation,
                title: Localization.string("diagnostics.terminal.undecided", "Terminal automation has not been asked yet"),
                status: .warning,
                fix: Localization.string("diagnostics.terminal.undecided.fix", "macOS asks the first time Limit Guard types into a Terminal tab."))
        case .unavailable:
            return DiagnosticItem(
                id: .terminalAutomation,
                title: Localization.string("diagnostics.terminal.unavailable", "Terminal automation could not be checked"),
                status: .warning,
                fix: Localization.string("diagnostics.terminal.unavailable.fix", "Open Terminal, then run the check again."))
        }
    }

    private static func notificationsItem(_ inputs: Inputs) -> DiagnosticItem {
        switch inputs.notifications {
        case .granted:
            return DiagnosticItem(
                id: .notifications,
                title: Localization.string("diagnostics.notifications.ok", "Notifications are allowed"),
                status: .ok)
        case .denied, .notDetermined, .unavailable:
            return DiagnosticItem(
                id: .notifications,
                title: Localization.string("diagnostics.notifications.off", "Notifications are not allowed"),
                status: .warning,
                fix: Localization.string("diagnostics.notifications.fix", "Allow them under System Settings → Notifications; the app works without them."))
        }
    }

    private static func approvalItem(_ inputs: Inputs) -> DiagnosticItem {
        let policy = inputs.configText.flatMap { approvalPolicy(inConfig: $0) }
        if approvalStatus(policy: policy) == .ok {
            return DiagnosticItem(
                id: .approvalPolicy,
                title: Localization.string("diagnostics.approval.ok", "Codex approval policy is “never”"),
                status: .ok)
        }
        let title: String
        if let policy {
            title = Localization.format("diagnostics.approval.interactive", "Codex approval policy is “%@”", policy)
        } else {
            title = Localization.string("diagnostics.approval.unset", "Codex approval policy is not set, so it asks for approval")
        }
        return DiagnosticItem(
            id: .approvalPolicy, title: title, status: .warning,
            fix: Localization.string(
                "diagnostics.approval.fix",
                "An unattended continue will stop at the first approval prompt. Set approval_policy to “never” in ~/.codex/config.toml for unattended runs."))
    }

    private static func keepAwakeItem(_ inputs: Inputs) -> DiagnosticItem {
        if inputs.keepAwakeActive {
            return DiagnosticItem(
                id: .keepAwake,
                title: Localization.string("diagnostics.keepAwake.on", "Keep-awake is active"),
                status: .ok)
        }
        return DiagnosticItem(
            id: .keepAwake,
            title: Localization.string("diagnostics.keepAwake.off", "Keep-awake is not active"),
            status: .warning,
            fix: Localization.string("diagnostics.keepAwake.fix", "It turns on while Limit Guard waits for a limit to come back."))
    }

    // MARK: - Report

    /// Plain text for the clipboard: marks, titles and fixes only. It holds no paths, account data or server messages.
    public static func report(_ items: [DiagnosticItem], appVersion: String) -> String {
        var lines = [Localization.format("diagnostics.report.header", "Cybokron Limit Guard %@ diagnostics", appVersion)]
        for item in items {
            lines.append("\(item.status.symbol) \(item.title)")
            if let fix = item.fix { lines.append("    → \(fix)") }
        }
        return lines.joined(separator: "\n")
    }
}
