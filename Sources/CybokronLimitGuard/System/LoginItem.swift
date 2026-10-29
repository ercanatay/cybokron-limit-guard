import ServiceManagement

/// Open at login for the app itself (`SMAppService.mainApp`).
enum LoginItem {
    enum State {
        case enabled
        /// Registered, but the owner still has to allow it in System Settings → Login Items.
        case requiresApproval
        case disabled
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
