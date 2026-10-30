import AppKit
import Combine
import LimitGuardCore
import OSLog

/// Looks for new releases on GitHub and installs them.
///
/// Automatic checks (on by default, `automaticallyChecks`) run shortly
/// after launch and then every six hours; "Check for Updates…" and Settings' "Check Now" check at
/// any time. When a check finds a newer release, the update window offers it with its release
/// notes. "Download and Install" downloads the release's universal disk image, copies the app out
/// of it, swaps it for the running app (keeping the old one to roll back to) and relaunches. The
/// file work happens in `UpdateInstaller`; this class keeps the state the windows show.
///
/// Settings → Updates → "Other Versions…" lists every published release and installs the chosen
/// one the same way, older or newer; `ReleaseHistory.state(_:afterInstalling:over:published:)`
/// decides which versions automatic checks skip afterwards. Going back to an older version, the
/// data files are copied aside first (`DowngradeProtection`), once the new version is downloaded
/// and checked.
@MainActor
final class AutoUpdater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(SemanticVersion)
        /// A newer release; `asset` is `nil` when it has no disk image to install from.
        case available(ReleaseInfo, asset: ReleaseAsset?)
        case downloading(ReleaseInfo, fraction: Double)
        case installing(ReleaseInfo)
        /// The new version is in place; the app is about to quit and reopen.
        case restarting(ReleaseInfo)
        /// `CYBOKRON_UPDATE_DRY_RUN` (development builds only) stopped the installation once the
        /// new app was staged.
        case stagedForDryRun(ReleaseInfo, path: String)
        case checkFailed(String)
        case installFailed(ReleaseInfo, asset: ReleaseAsset?, message: String)
    }

    /// The published releases for "Other Versions…".
    enum ReleaseListStatus: Equatable {
        case idle
        case loading
        /// Installable releases, newest first; see `ReleaseHistory.installable`.
        case loaded([ReleaseInfo])
        case failed(String)
    }

    /// How long a loaded release list is shown again without asking GitHub, so opening and closing
    /// "Other Versions…" doesn't use up GitHub's hourly limit.
    private static let releaseListLifetime: TimeInterval = 10 * 60

    /// Delay of the check at launch, so it doesn't compete with starting up.
    private static let launchCheckDelay: Duration = .seconds(5)

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var releaseList: ReleaseListStatus = .idle
    /// Versions automatic checks don't offer, newest first.
    @Published private(set) var skippedVersions: [String] = []
    /// Whether the app checks for updates by itself; kept in the update state.
    @Published private(set) var automaticallyChecks = true
    /// The running app's version; `nil` when the bundle has none (e.g. `swift run`).
    let currentVersion: SemanticVersion?

    /// Brings up the update window; set by the app delegate.
    var showWindow: () -> Void = {}
    /// Closes the update window; set by the app delegate.
    var closeWindow: () -> Void = {}
    /// Whether the update window is on screen; set by the app delegate.
    var isWindowShown: () -> Bool = { false }
    /// Called right before the app quits to reopen as the new version; set by the app delegate.
    var beforeRelaunch: () -> Void = {}

    private let feed: ReleaseFetching & ReleaseListFetching
    private let installer: UpdateInstaller
    private let statePersistence: JSONFileUpdateStatePersistence
    private var state: UpdateState {
        didSet { skippedVersions = state.skippedVersions }
    }
    /// The release list "Other Versions…" showed, while the version picked there is being installed
    /// (also through Try Again); `nil` for an update offered by a check.
    private var pickedFromReleases: [ReleaseInfo]?
    private var releaseListDate: Date?
    private let isDryRun: Bool
    private var tickTimer: Timer?
    private var hasHandledLaunch = false
    private var subscriptions: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.cybokron.limitguard", category: "Updates")

    init(
        installer: UpdateInstaller = UpdateInstaller(),
        statePersistence: JSONFileUpdateStatePersistence = JSONFileUpdateStatePersistence()
    ) {
        self.installer = installer
        self.statePersistence = statePersistence
        currentVersion = SemanticVersion(AppInfo.version)
        let feed = GitHubReleaseFeed(appVersion: AppInfo.version)
        self.feed = feed
        state = statePersistence.load()
        lastCheckDate = state.lastCheckDate
        skippedVersions = state.skippedVersions
        automaticallyChecks = state.automaticallyChecks
        // Development builds only; release builds ignore the variable.
        isDryRun = DevelopmentOverrides.value(UpdateInstaller.dryRunVariable) != nil
        if feed.url != UpdateLinks.latestReleaseAPI {
            logger.notice("Update feed overridden: \(feed.url.absoluteString, privacy: .public)")
        }
        if feed.listURL != UpdateLinks.releasesAPI {
            logger.notice("Release list overridden: \(feed.listURL.absoluteString, privacy: .public)")
        }
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing, .restarting: return true
        default: return false
        }
    }

    /// An offered update or a failed installation, which an automatic check would replace.
    private var showsOfferOrFailure: Bool {
        switch status {
        case .available, .installFailed: return true
        default: return false
        }
    }

    /// Cleans up after earlier updates, then follows the automatic-check setting. Call once the app
    /// has finished launching.
    func start() {
        installer.removeLeftovers(keepingBackups: 1)
        $automaticallyChecks
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOn in self?.automaticChecksChanged(isOn) }
            .store(in: &subscriptions)
        // Timers stand still while the Mac sleeps; look right after waking up.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.checkIfDue() }
            .store(in: &subscriptions)
    }

    // MARK: - Checking

    /// "Check for Updates…": shows the update window, which follows the check.
    func checkForUpdatesFromMenu() {
        showWindow()
        checkNow()
    }

    /// Checks right away, unless a check or an installation is under way.
    func checkNow() {
        check(userInitiated: true)
    }

    /// The first call comes right at `start()`; later ones when the setting changes.
    private func automaticChecksChanged(_ isOn: Bool) {
        let isLaunch = !hasHandledLaunch
        hasHandledLaunch = true
        tickTimer?.invalidate()
        tickTimer = nil
        guard isOn else {
            logger.notice("Automatic update checks are off")
            return
        }
        let timer = Timer(timeInterval: UpdateSchedule.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        if !isLaunch {
            // Turned on in Settings.
            checkIfDue()
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.launchCheckDelay)
                guard let self, self.automaticallyChecks else { return }
                self.check(userInitiated: false)
            }
        }
    }

    private func checkIfDue() {
        guard automaticallyChecks,
              UpdateSchedule.isCheckDue(lastCheck: state.lastCheckDate, now: Date())
        else { return }
        check(userInitiated: false)
    }

    private func check(userInitiated: Bool) {
        guard !isBusy else { return }
        if !userInitiated, !UpdateSchedule.mayCheckAutomatically(showsOfferOrFailure: showsOfferOrFailure, windowIsShown: isWindowShown()) {
            logger.notice("Skipping the automatic update check: the update window shows an update or a failed installation")
            return
        }
        guard let currentVersion else {
            status = .checkFailed(UpdateCheckError.unknownCurrentVersion.localizedDescription)
            return
        }
        logger.notice("Checking for updates (\(userInitiated ? "user" : "automatic", privacy: .public))")
        status = .checking
        Task { @MainActor [weak self, feed] in
            let result: Result<ReleaseInfo, Error>
            do {
                result = .success(try await feed.latestRelease())
            } catch {
                result = .failure(error)
            }
            self?.finishCheck(result, current: currentVersion, userInitiated: userInitiated)
        }
    }

    private func finishCheck(_ result: Result<ReleaseInfo, Error>, current: SemanticVersion, userInitiated: Bool) {
        state.lastCheckDate = Date()
        lastCheckDate = state.lastCheckDate
        saveState()
        switch result {
        case .success(let release):
            switch UpdateDecision.evaluate(current: current, latest: release) {
            case .upToDate(_, let latest):
                logger.notice("Up to date: \(current, privacy: .public) (latest release \(latest, privacy: .public))")
                status = .upToDate(current)
            case .available(let release, let asset):
                offer(release, asset: asset, userInitiated: userInitiated)
            case .availableWithoutInstaller(let release):
                offer(release, asset: nil, userInitiated: userInitiated)
            }
        case .failure(let error):
            logger.error("Update check failed: \(String(describing: error), privacy: .public)")
            status = .checkFailed(error.localizedDescription)
        }
    }

    private func offer(_ release: ReleaseInfo, asset: ReleaseAsset?, userInitiated: Bool) {
        logger.notice("Update available: \(release.version, privacy: .public), asset \(asset?.name ?? "none", privacy: .public)")
        status = .available(release, asset: asset)
        // Automatic checks bring up the window, except for a version the user skipped.
        if !userInitiated && !state.isSkipped(release.version) {
            showWindow()
        }
    }

    // MARK: - Choices in the update window

    /// Skips `release` for automatic checks and closes the window.
    func skip(_ release: ReleaseInfo) {
        state.skip(release.version)
        saveState()
        closeWindow()
    }

    /// Closes the window; the next automatic check offers the update again.
    func remindLater() {
        closeWindow()
    }

    /// Downloads the offered release (or tries the failed one again), swaps it for the running app
    /// and relaunches.
    func downloadAndInstall() {
        switch status {
        case .available(let release, let asset?):
            pickedFromReleases = nil
            install(release, asset: asset)
        case .installFailed(let release, let asset?, _):
            install(release, asset: asset)
        default:
            return
        }
    }

    // MARK: - Other versions

    /// Loads the published releases for "Other Versions…", unless they're loading already or were
    /// loaded in the last few minutes (`force` loads them anyway).
    func loadReleases(force: Bool = false) {
        guard releaseList != .loading else { return }
        if !force, case .loaded = releaseList, let releaseListDate,
           !UpdateSchedule.isCheckDue(lastCheck: releaseListDate, now: Date(), interval: Self.releaseListLifetime) {
            return
        }
        logger.notice("Loading the release list")
        releaseList = .loading
        Task { @MainActor [weak self, feed] in
            do {
                let releases = try await feed.releases()
                self?.releaseListDate = Date()
                self?.releaseList = .loaded(ReleaseHistory.installable(releases))
            } catch {
                self?.logger.error("Loading the release list failed: \(String(describing: error), privacy: .public)")
                self?.releaseList = .failed(error.localizedDescription)
            }
        }
    }

    /// Installs `release`, picked from `releases` in "Other Versions…", in the update window. Once
    /// it's in place, the skipped versions follow `ReleaseHistory.state(_:afterInstalling:…)`.
    /// Does nothing while a check or an installation is under way (the sheet says so first).
    func installPicked(_ release: ReleaseInfo, from releases: [ReleaseInfo]) {
        guard let asset = release.installerAsset else { return }
        guard !isBusy else {
            logger.notice("Not installing \(release.version, privacy: .public) from Other Versions: an update check or installation is under way")
            return
        }
        logger.notice("Installing version \(release.version, privacy: .public) from Other Versions")
        pickedFromReleases = releases
        showWindow()
        install(release, asset: asset)
    }

    /// Turns the automatic checks on or off (Settings → Updates).
    func setAutomaticallyChecks(_ isOn: Bool) {
        guard isOn != automaticallyChecks else { return }
        automaticallyChecks = isOn
        state.automaticallyChecks = isOn
        saveState()
    }

    /// Clears the skipped versions, so automatic checks offer every newer release again.
    func clearSkippedVersions() {
        state.skippedVersions = []
        saveState()
    }

    // MARK: - Installing

    private func install(_ release: ReleaseInfo, asset: ReleaseAsset) {
        guard !isBusy else { return }
        let appURL = Bundle.main.bundleURL
        if !isDryRun, let problem = UpdateInstaller.installLocationProblem(for: appURL) {
            status = .installFailed(release, asset: asset, message: problem)
            return
        }
        logger.notice("Downloading \(asset.downloadURL.absoluteString, privacy: .public)")
        status = .downloading(release, fraction: 0)
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.downloadProgressed(fraction) }
        }
        let currentVersion = self.currentVersion
        Task { @MainActor [weak self, installer, isDryRun] in
            do {
                let diskImage = try await installer.download(asset, progress: progress)
                self?.status = .installing(release)
                // A Developer ID signed copy only takes a disk image and an app signed with a
                // Developer ID of its own team; the disk image is checked before it's mounted.
                // Release builds name that team in Info.plist, so it never depends on reading the
                // running app's signature.
                let runningTeam = UpdateInstaller.expectedTeamIdentifier(
                    pinned: AppInfo.updateTeamIdentifier,
                    running: await installer.signature(ofAppAt: appURL)?.signingTeam
                )
                let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
                let staged = try await installer.stageApp(
                    fromDiskImage: diskImage,
                    appName: AppInfo.name,
                    expectedTeamIdentifier: runningTeam
                )
                try UpdateInstaller.validateStagedApp(
                    staged,
                    bundleIdentifier: bundleIdentifier,
                    version: release.version
                )
                try await installer.verifySignature(
                    ofStagedApp: staged,
                    bundleIdentifier: bundleIdentifier,
                    expectedTeamIdentifier: runningTeam
                )
                // Going back to an older version: a copy of the data files first, which that version
                // may not understand. Without the copies, nothing is installed. The current version
                // is captured up front, so the copy step never depends on `self` being alive.
                let backup: URL? = try await DowngradeProtection.replacing(installing: release.version, over: currentVersion) {
                    if isDryRun { return nil }
                    return try await Task.detached {
                        try installer.replace(installedApp: appURL, with: staged)
                    }.value
                }
                guard let backup else {
                    self?.logger.notice("Dry run: staged \(staged.path, privacy: .public); nothing replaced")
                    self?.status = .stagedForDryRun(release, path: staged.path)
                    return
                }
                self?.logger.notice("Installed \(release.version, privacy: .public); previous version at \(backup.path, privacy: .public)")
                self?.updateSkippedVersions(afterInstalling: release)
                self?.status = .restarting(release)
                // Let the "restarting" text show before the app quits.
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.relaunch(appURL, backup: backup, release: release, asset: asset)
            } catch {
                self?.logger.error("Update failed: \(String(describing: error), privacy: .public)")
                self?.status = .installFailed(release, asset: asset, message: error.localizedDescription)
            }
        }
    }

    /// After a version picked in "Other Versions…" is in place: skip the newer releases (going back)
    /// or clear the skipped ones (going up).
    private func updateSkippedVersions(afterInstalling release: ReleaseInfo) {
        guard let releases = pickedFromReleases, let currentVersion else { return }
        pickedFromReleases = nil
        state = ReleaseHistory.state(state, afterInstalling: release.version, over: currentVersion, published: releases)
        logger.notice("Skipped versions now: \(self.state.skippedVersions.joined(separator: ", "), privacy: .public)")
        saveState()
    }

    private func downloadProgressed(_ fraction: Double) {
        guard case .downloading(let release, _) = status else { return }
        status = .downloading(release, fraction: fraction)
    }

    /// Starts a helper that opens the new version once this process has quit, then quits.
    private func relaunch(_ appURL: URL, backup: URL, release: ReleaseInfo, asset: ReleaseAsset) {
        let process = Process()
        process.executableURL = UpdateInstaller.shell
        process.arguments = UpdateInstaller.relaunchArguments(
            processID: ProcessInfo.processInfo.processIdentifier,
            appURL: appURL,
            backupURL: backup
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        beforeRelaunch()
        do {
            try process.run()
        } catch {
            logger.error("Relaunch helper failed: \(String(describing: error), privacy: .public)")
            status = .installFailed(
                release,
                asset: nil,
                message: L10n.UpdateWindow.relaunchFailed(release.version.description)
            )
            return
        }
        NSApp.terminate(nil)
    }

    private func saveState() {
        do {
            try statePersistence.save(state)
        } catch {
            logger.error("Saving the update state failed: \(String(describing: error), privacy: .public)")
        }
    }
}
