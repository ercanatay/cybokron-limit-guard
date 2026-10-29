import AppKit
import Combine
import LimitGuardCore
import OSLog

extension Notification.Name {
    /// Posted after `SettingsModel` has saved a change, so the Engine can act on it right away.
    static let limitGuardSettingsChanged = Notification.Name("com.cybokron.limitguard.settingsChanged")
}

/// Builds the real Engine from the system pieces and keeps it running (start after the legal
/// notice, wake on system wake and on settings changes, stop on quit).
@MainActor
final class EngineHost {
    private static let logger = Logger(subsystem: "com.cybokron.limitguard", category: "engine-host")
    private static let loginItemTriedKey = "loginItem.registrationTried"

    private let settingsStore: JSONStore<Settings>
    let notifier = Notifier()
    private(set) var engine: Engine?
    private(set) var codexFound = true
    /// Called whenever the Engine's published state changes (the menu status line).
    var onChange: (() -> Void)?

    private lazy var keepAwake = KeepAwake(isEnabled: { [settingsStore] in
        ((try? settingsStore.load()?.clamped()) ?? Settings()).keepAwake
    })
    private var subscriptions = Set<AnyCancellable>()
    private var wakeTask: Task<Void, Never>?

    init(settingsStore: JSONStore<Settings>) {
        self.settingsStore = settingsStore
    }

    var isKeepAwakeActive: Bool { keepAwake.isActive }

    /// Starts everything. Call once, after the legal notice has been accepted.
    func start() async {
        guard engine == nil else { return }
        syncLoginItem()
        notifier.start()

        let url = settingsStore.url
        let locator = CodexLocator()
        // The path is resolved again for every connection, so a changed override takes effect.
        let resolve: @Sendable () -> URL = {
            let override = (try? JSONStore<Settings>(url: url, schemaVersion: 1).load())?.codexPathOverride
            return locator.resolve(override: override) ?? URL(fileURLWithPath: "/nonexistent/codex")
        }
        // The login-shell lookup and `codex --version` run off the main thread and may take 5 s at most.
        let initial = await Self.withTimeout(seconds: 5) { resolve() } ?? URL(fileURLWithPath: "/nonexistent/codex")
        codexFound = FileManager.default.isExecutableFile(atPath: initial.path)
        let version: String? = codexFound
            ? await Self.withTimeout(seconds: 5) { await locator.version(of: initial) } ?? nil
            : nil
        if !codexFound { Self.logger.error("codex executable not found") }

        let clientVersion = AppInfo.version
        let account = CodexAccountService(
            client: AppServerClient(
                transportFactory: { ProcessTransport(executable: resolve(), arguments: ["app-server"]) },
                clientName: "cybokron-limit-guard", clientVersion: clientVersion),
            now: { Date() })
        let delivery = AppServerDelivery(client: AppServerClient(
            transportFactory: { WebSocketTransport.codexProxy(executable: resolve()) },
            clientName: "cybokron-limit-guard", clientVersion: clientVersion))
        let sessions = SessionScanner(
            index: ThreadIndex(databaseURL: ThreadIndex.locateDatabase() ?? Self.fallbackIndexURL),
            reader: RolloutReader())

        let store = settingsStore
        let engine = Engine(Engine.Dependencies(
            clock: SystemClock(),
            environment: AppEngineEnvironment(notifier: notifier, keepAwake: keepAwake),
            account: account, sessions: sessions, delivery: delivery,
            dataDirectory: AppPaths.dataDirectory,
            // An unreadable file means defaults: the notice counts as not accepted, so nothing acts.
            settings: { (try? store.load()?.clamped()) ?? Settings() },
            codexVersion: version))
        self.engine = engine
        notifier.onCancelCountdown = { [weak engine] in engine?.cancelNextAction() }
        // Only while that continue is still unconfirmed, so a late tap can't start a continue for a later stop.
        notifier.onSendAgain = { [weak engine] threadId in
            guard let engine, engine.tabs.contains(where: { $0.threadId == threadId && $0.continueStatus == .unconfirmed })
            else { return }
            Task { await engine.continueNow(threadId: threadId) }
        }

        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onChange?() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak engine] _ in Task { @MainActor in engine?.wake() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .limitGuardSettingsChanged)
            .sink { [weak self] _ in Task { @MainActor in self?.settingsChanged() } }
            .store(in: &subscriptions)

        engine.start()
        onChange?()
    }

    /// Keep-awake follows at once; the Engine's extra tick waits until the changes stop for a second.
    private func settingsChanged() {
        keepAwake.settingsChanged()
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.engine?.wake()
        }
    }

    func stop() {
        wakeTask?.cancel()
        engine?.stop()
        keepAwake.release()
    }

    /// `SMAppService` follows `Settings.launchAtLogin` at startup, but only for an installed copy
    /// (never a debug build). The first registration is tried once; after that an owner who removed
    /// the item in System Settings is not fought.
    private func syncLoginItem() {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        guard LoginItemPolicy.shouldSync(bundleURL: Bundle.main.bundleURL, isDebugBuild: isDebug) else {
            Self.logger.notice("login item sync skipped (not an installed release copy)")
            return
        }
        let wanted = ((try? settingsStore.load()?.clamped()) ?? Settings()).launchAtLogin
        let defaults = UserDefaults.standard
        switch (wanted, LoginItem.state) {
        case (true, .disabled) where !defaults.bool(forKey: Self.loginItemTriedKey):
            defaults.set(true, forKey: Self.loginItemTriedKey)
            do { try LoginItem.setEnabled(true) } catch {
                Self.logger.error("login item not registered: \(String(describing: error), privacy: .public)")
            }
        case (false, .enabled), (false, .requiresApproval):
            do { try LoginItem.setEnabled(false) } catch {
                Self.logger.error("login item not removed: \(String(describing: error), privacy: .public)")
            }
        default:
            break
        }
    }

    /// Used only when no `state_*.sqlite` exists yet: the scanner then finds nothing.
    private static var fallbackIndexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/state_5.sqlite")
    }

    /// Runs `work` off the main thread and gives up after `seconds` (nil). The abandoned work finishes on its own.
    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task.detached { once.resume(await work()) }
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(nil)
            }
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func resume(_ value: T?) {
        let taken = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
