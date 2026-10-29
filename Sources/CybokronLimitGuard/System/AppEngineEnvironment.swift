import LimitGuardCore

/// The Engine's view of the system: Codex tabs from `ps`/`lsof`, notifications, keep-awake.
struct AppEngineEnvironment: EngineEnvironment {
    let lister = CodexProcessLister()
    let notifier: Notifier
    let keepAwake: KeepAwake

    func terminalTabs() async -> [TerminalTab]? {
        await lister.listTabs()
    }

    func notify(_ note: EngineNote) async {
        await notifier.post(note)
    }

    func setKeepAwake(_ on: Bool) async {
        await keepAwake.set(on)
    }
}
