import Foundation
import Testing
@testable import LimitGuardCore

@Suite("Diagnostics core")
struct DiagnosticsCoreTests {
    // MARK: - config.toml

    @Test func approvalPolicyNeverIsOk() {
        #expect(DiagnosticsCore.approvalPolicy(inConfig: #"approval_policy = "never""#) == "never")
        #expect(DiagnosticsCore.approvalStatus(policy: "never") == .ok)
    }

    @Test func approvalPolicyInteractiveOrMissingWarns() {
        #expect(DiagnosticsCore.approvalPolicy(inConfig: #"approval_policy = "on-request""#) == "on-request")
        #expect(DiagnosticsCore.approvalStatus(policy: "on-request") == .warning)
        #expect(DiagnosticsCore.approvalPolicy(inConfig: "model = \"x\"\n") == nil)
        #expect(DiagnosticsCore.approvalStatus(policy: nil) == .warning)
    }

    @Test func approvalPolicyParserIgnoresSectionsCommentsAndSpacing() {
        let toml = """
        # approval_policy = "never"
        model = "gpt"
          approval_policy   =   'untrusted'   # comment
        [profiles.fast]
        approval_policy = "never"
        """
        #expect(DiagnosticsCore.approvalPolicy(inConfig: toml) == "untrusted")
        // Only inside a section: not the top-level key.
        #expect(DiagnosticsCore.approvalPolicy(inConfig: "[profiles.x]\napproval_policy = \"never\"\n") == nil)
        #expect(DiagnosticsCore.approvalPolicy(inConfig: "approval_policy_extra = \"never\"") == nil)
    }

    // MARK: - items

    private func inputs(
        codex: Bool = true,
        limits: LimitsProbe = .read(.full),
        config: String? = #"approval_policy = "never""#,
        notifications: PermissionState = .granted,
        keepAwake: Bool = true
    ) -> DiagnosticsCore.Inputs {
        DiagnosticsCore.Inputs(
            codexVersion: codex ? "codex-cli 0.165.0" : nil, codexFound: codex,
            lastTestedCodexVersion: "0.165.0", limits: limits, configText: config,
            notifications: notifications, keepAwakeActive: keepAwake)
    }

    private func status(_ id: DiagnosticItem.ID, _ items: [DiagnosticItem]) -> DiagnosticItem.Status? {
        items.first { $0.id == id }?.status
    }

    @Test func everythingHealthyIsAllOk() {
        let items = DiagnosticsCore.items(inputs())
        #expect(items.allSatisfy { $0.status == .ok })
        #expect(items.allSatisfy { $0.fix == nil })
    }

    @Test func codexNotFoundFailsAndSkipsDependentChecks() {
        let items = DiagnosticsCore.items(inputs(codex: false, limits: .notRun))
        #expect(status(.codexFound, items) == .failed)
        #expect(items.first { $0.id == .codexFound }?.fix != nil)
        #expect(status(.appServer, items) == .failed)
        #expect(status(.signedIn, items) == .warning)
    }

    @Test func readOnlyHealthWarns() {
        let items = DiagnosticsCore.items(inputs(limits: .read(.readOnly(reason: "x"))))
        #expect(status(.rateLimitsDecode, items) == .warning)
        #expect(status(.signedIn, items) == .ok)
        #expect(status(.appServer, items) == .ok)
    }

    @Test func rpcErrorMeansReachableButNotSignedIn() {
        let items = DiagnosticsCore.items(inputs(limits: .rpcError("not signed in")))
        #expect(status(.appServer, items) == .ok)
        #expect(status(.signedIn, items) == .failed)
    }

    @Test func unreachableServerFails() {
        let items = DiagnosticsCore.items(inputs(limits: .unreachable("exit 1")))
        #expect(status(.appServer, items) == .failed)
    }

    @Test func probeFromError() {
        #expect(LimitsProbe(error: AppServerError.rpcError(code: -1, message: "m")) == .rpcError("m"))
        #expect(LimitsProbe(error: AppServerError.timeout) != .rpcError("m"))
    }

    @Test func newerCodexThanTestedWarns() {
        var value = inputs()
        value.codexVersion = "codex-cli 0.170.2"
        #expect(status(.codexFound, DiagnosticsCore.items(value)) == .warning)
        value.codexVersion = "codex-cli 0.165.0"
        #expect(status(.codexFound, DiagnosticsCore.items(value)) == .ok)
    }

    @Test func permissionsAndKeepAwake() {
        let denied = DiagnosticsCore.items(inputs(notifications: .denied, keepAwake: false))
        #expect(status(.notifications, denied) == .warning)
        #expect(status(.keepAwake, denied) == .warning)
        let undecided = DiagnosticsCore.items(inputs(notifications: .notDetermined))
        #expect(status(.notifications, undecided) == .warning)
        #expect(status(.approvalPolicy, DiagnosticsCore.items(inputs(config: nil))) == .warning)
    }

    @Test func reportListsEveryItemWithoutPathsOrSecrets() {
        let items = DiagnosticsCore.items(inputs(limits: .rpcError("secret-token-123 failed")))
        let report = DiagnosticsCore.report(items, appVersion: "0.1.0")
        #expect(report.contains("0.1.0"))
        #expect(report.contains("✗"))
        #expect(!report.contains("secret-token-123"))
        #expect(!report.contains(NSHomeDirectory()))
        #expect(report.split(separator: "\n").count >= items.count)
    }
}
