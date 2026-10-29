#if DEBUG
import AppKit
import LimitGuardCore

/// Debug builds only: `-LGScreenshotScene <scene> [-LGAppearance light|dark]` runs the app on made-up
/// data (`ScreenshotFixture`) for the README screenshots (`scripts/screenshots.sh`). The data folder
/// is a temporary one, the Engine talks to fakes (no codex process, no Terminal, no notifications),
/// and the scene's window opens at launch. Its window number is printed as `LG_WINDOW_ID=<id>`.
enum ScreenshotMode {
    enum Scene: String, CaseIterable {
        case popover
        case settingsGeneral = "settings-general"
        case settingsContinue = "settings-continue"
        case settingsResets = "settings-resets"
        case activity, chart, about, notice

        /// The Settings pane the scene shows (`SettingsPane` raw values).
        var settingsPane: String? {
            switch self {
            case .settingsGeneral: "general"
            case .settingsContinue: "continueText"
            case .settingsResets: "resets"
            default: nil
            }
        }
    }

    static let scene: Scene? = UserDefaults.standard.string(forKey: "LGScreenshotScene").flatMap(Scene.init(rawValue:))
    static var isActive: Bool { scene != nil }
    static let isDark = UserDefaults.standard.string(forKey: "LGAppearance") == "dark"
    static let fixture = ScreenshotFixture(now: Date(), home: NSHomeDirectory())
    /// The popover's scrolling part in the screenshots (the app caps it at 520 points).
    static let popoverContentHeight: CGFloat = 656
    /// What General shows as the Codex executable, instead of the one found on this Mac.
    static let codexPath = URL(fileURLWithPath: "/opt/homebrew/bin/codex")

    /// Call first in `main()`, before anything reads `AppPaths`: points the data folder at a fresh
    /// temporary one (unless `CYBOKRON_LG_DATA_DIR` names one) and fills it from the fixture.
    @MainActor
    static func prepare() {
        guard let scene else { return }
        let variable = DataDirectory.overrideVariable
        if ProcessInfo.processInfo.environment[variable]?.isEmpty ?? true {
            let temporary = FileManager.default.temporaryDirectory
                .appending(path: "limit-guard-screenshots-\(UUID().uuidString)", directoryHint: .isDirectory)
            setenv(variable, temporary.path, 1)
        }
        let directory = DataDirectory.url
        let real = DataDirectory.resolve(environment: [:], honoursOverride: false)
        guard directory.standardizedFileURL.path != real.standardizedFileURL.path else {
            fatalError("screenshot mode never uses the real data folder")
        }
        do {
            try fixture.seed(into: directory)
            if scene == .notice {
                let store = JSONStore<Settings>(url: AppPaths.settingsURL, schemaVersion: 1)
                var settings = fixture.settings
                settings.noticeAcceptedVersion = nil
                settings.noticeAcceptedAt = nil
                try store.save(settings)
            }
        } catch {
            fatalError("screenshot data not written: \(error)")
        }
        if let pane = scene.settingsPane {
            UserDefaults.standard.register(defaults: ["SettingsSelectedPane": pane])
        }
    }

    @MainActor
    static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    @MainActor private static var backdrop: NSWindow?

    /// A plain window under the popover or the notice, so their translucent material shows a flat
    /// colour instead of whatever is on the screen behind them.
    @MainActor
    static func showBackdrop() {
        guard let screen = NSScreen.main?.frame else { return }
        let window = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        backdrop = window
    }

    /// The real Engine on the fixture's fakes.
    @MainActor
    static func makeEngine() -> Engine {
        let store = JSONStore<Settings>(url: AppPaths.settingsURL, schemaVersion: 1)
        let account = CodexAccountService(
            client: AppServerClient(
                transportFactory: { ScreenshotAppServer(fixture: fixture) },
                clientName: "cybokron-limit-guard", clientVersion: AppInfo.version),
            now: { Date() })
        return Engine(Engine.Dependencies(
            clock: SystemClock(),
            environment: ScreenshotEnvironment(fixture: fixture),
            account: account,
            sessions: ScreenshotSessions(fixture: fixture),
            delivery: ScreenshotDelivery(fixture: fixture),
            dataDirectory: AppPaths.dataDirectory,
            settings: { (try? store.load()?.clamped()) ?? Settings() },
            codexVersion: ScreenshotFixture.codexVersion))
    }

    static func chartContent() -> UsageChartContent {
        UsageChartContent(
            report: try? UsageReport.decode(from: Data(fixture.usageResult.utf8)),
            samples: fixture.history,
            weeklyResetsAt: fixture.weeklyResetsAt,
            now: Date())
    }

    /// Prints the window's number once it has had time to draw, for `screencapture -l`.
    @MainActor
    static func announce(_ window: @escaping () -> NSWindow?, after delay: TimeInterval = 1.5) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let window = window(), window.windowNumber > 0 else {
                    announce(window, after: 0.5)
                    return
                }
                FileHandle.standardOutput.write(Data("LG_WINDOW_ID=\(window.windowNumber)\n".utf8))
            }
        }
        // Common modes include the modal panel mode, so this also fires while the notice is open.
        RunLoop.main.add(timer, forMode: .common)
    }
}
#endif
