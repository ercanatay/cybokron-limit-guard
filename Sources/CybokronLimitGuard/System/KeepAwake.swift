import Foundation
import IOKit.pwr_mgt
import OSLog

/// Keeps the Mac from idle-sleeping while Limit Guard waits for a limit to reset (spec D14).
/// Holds one power assertion at most; `set(_:)` and `settingsChanged()` are idempotent.
@MainActor
final class KeepAwake {
    private static let logger = Logger(subsystem: "com.cybokron.limitguard", category: "keep-awake")
    private static let reason = "Waiting for the Codex usage limit to reset"

    private let isEnabled: () -> Bool
    private var requested = false
    private var assertion: IOPMAssertionID?

    /// `isEnabled`: the current `Settings.keepAwake`.
    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    var isActive: Bool { assertion != nil }

    /// What the Engine wants; the setting can still veto it.
    func set(_ on: Bool) {
        requested = on
        apply()
    }

    /// Re-checks the setting (the owner may have turned keep-awake off while it was on).
    func settingsChanged() {
        apply()
    }

    func release() {
        requested = false
        apply()
    }

    private func apply() {
        let hold = requested && isEnabled()
        if hold, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.reason as CFString, &id)
            if result == kIOReturnSuccess {
                assertion = id
            } else {
                Self.logger.error("keep-awake assertion failed: \(result, privacy: .public)")
            }
        } else if !hold, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
