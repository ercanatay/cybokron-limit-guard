import Foundation
import Testing
@testable import LimitGuardCore

/// Stands in for hdiutil and ditto: "attaching" puts a copy of `diskImageApp` (and an Applications
/// link, like the real disk image) at the mount point, ditto copies with FileManager.
final class FakeDiskImageTools: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let diskImageApp: URL?

    init(diskImageApp: URL?) {
        self.diskImageApp = diskImageApp
    }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        lock.withLock { _calls.append([tool.lastPathComponent] + arguments) }
        let fileManager = FileManager.default
        switch (tool.lastPathComponent, arguments.first) {
        case ("hdiutil", "attach"):
            guard let index = arguments.firstIndex(of: "-mountpoint") else { return ToolResult(status: 1, output: "no mount point") }
            let mountPoint = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            try fileManager.createSymbolicLink(at: mountPoint.appending(path: "Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
            if let diskImageApp {
                try fileManager.copyItem(at: diskImageApp, to: mountPoint.appending(path: diskImageApp.lastPathComponent))
            }
            return ToolResult(status: 0, output: "")
        case ("hdiutil", "detach"):
            // Unmounting leaves the mount point empty.
            let mountPoint = URL(fileURLWithPath: arguments[1], isDirectory: true)
            for item in (try? fileManager.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? [] {
                try fileManager.removeItem(at: item)
            }
            return ToolResult(status: 0, output: "")
        case ("ditto", _):
            try fileManager.copyItem(at: URL(fileURLWithPath: arguments[0]), to: URL(fileURLWithPath: arguments[1]))
            return ToolResult(status: 0, output: "")
        default:
            return ToolResult(status: 1, output: "unexpected tool")
        }
    }
}

/// Runs tools through `base`, but tries a failed `hdiutil attach` again after each of `delays`: on a
/// busy CI machine attaching sometimes fails at first with "Resource temporarily unavailable". Other
/// tools and other failures pass straight through; once every retry failed, the last failure is
/// returned as it is. Only for the tests that use the real hdiutil.
struct DiskImageAttachRetryingRunner: ToolRunning {
    static let defaultDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    let base: ToolRunning
    let delays: [Duration]
    let sleep: @Sendable (Duration) async -> Void

    init(
        base: ToolRunning = SystemToolRunner(),
        delays: [Duration] = DiskImageAttachRetryingRunner.defaultDelays,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.base = base
        self.delays = delays
        self.sleep = sleep
    }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        var result = try await base.run(tool, arguments: arguments)
        guard tool.lastPathComponent == "hdiutil", arguments.first == "attach" else { return result }
        for delay in delays where !result.succeeded {
            await sleep(delay)
            result = try await base.run(tool, arguments: arguments)
        }
        return result
    }
}

/// Fails `hdiutil attach` the first `failures` times, then succeeds; records every call.
final class FlakyAttachTools: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private var _calls: [[String]] = []

    init(failures: Int) {
        remainingFailures = failures
    }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        lock.withLock {
            _calls.append([tool.lastPathComponent] + arguments)
            guard remainingFailures > 0 else { return ToolResult(status: 0, output: "") }
            remainingFailures -= 1
            return ToolResult(status: 1, output: "hdiutil: attach failed - Resource temporarily unavailable")
        }
    }
}

/// Records the delays it was asked to wait, without waiting.
final class RecordedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Duration] = []

    var delays: [Duration] { lock.withLock { _delays } }

    func sleep(_ delay: Duration) async {
        lock.withLock { _delays.append(delay) }
    }
}

@Suite("Disk image attach retries (test support)")
struct DiskImageAttachRetryTests {
    private let attach = ["attach", "-readonly", "-nobrowse", "/tmp/x.dmg"]

    @Test func transientFailuresAreRetriedUntilAttachSucceeds() async throws {
        let tools = FlakyAttachTools(failures: 2)
        let sleeps = RecordedSleeps()
        let runner = DiskImageAttachRetryingRunner(base: tools, sleep: sleeps.sleep)

        let result = try await runner.run(UpdateInstaller.hdiutil, arguments: attach)

        #expect(result.succeeded)
        #expect(tools.calls.count == 3)
        #expect(sleeps.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test func persistentFailureIsReportedAfterThreeRetries() async throws {
        let tools = FlakyAttachTools(failures: 10)
        let sleeps = RecordedSleeps()
        let runner = DiskImageAttachRetryingRunner(base: tools, sleep: sleeps.sleep)

        let result = try await runner.run(UpdateInstaller.hdiutil, arguments: attach)

        #expect(!result.succeeded)
        #expect(result.output.contains("Resource temporarily unavailable"))
        #expect(tools.calls.count == 4)
        #expect(sleeps.delays == [.milliseconds(500), .seconds(1), .seconds(2)])
    }

    @Test func persistentFailureStillFailsStaging() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let sleeps = RecordedSleeps()
        let runner = DiskImageAttachRetryingRunner(base: FlakyAttachTools(failures: 10), sleep: sleeps.sleep)
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: runner)

        await #expect(throws: UpdateInstallError.mountFailed("hdiutil: attach failed - Resource temporarily unavailable")) {
            try await installer.stageApp(fromDiskImage: temporary.url.appending(path: "update.dmg"), appName: "Any", expectedTeamIdentifier: nil)
        }
        #expect(sleeps.delays.count == 3)
    }

    @Test func otherToolsAndDetachAreNotRetried() async throws {
        let sleeps = RecordedSleeps()
        let tools = FlakyAttachTools(failures: 10)
        let runner = DiskImageAttachRetryingRunner(base: tools, sleep: sleeps.sleep)

        let detach = try await runner.run(UpdateInstaller.hdiutil, arguments: ["detach", "/tmp/mount"])
        let ditto = try await runner.run(UpdateInstaller.ditto, arguments: ["a", "b"])

        #expect(!detach.succeeded && !ditto.succeeded)
        #expect(tools.calls.count == 2)
        #expect(sleeps.delays.isEmpty)
    }
}

@Suite("Update installer")
struct UpdateInstallerTests {
    static let appName = "Cybokron Limit Guard"
    static let bundleIdentifier = "com.cybokron.limitguard"

    /// A minimal app bundle with an executable, in `folder`.
    private func makeApp(in folder: URL, version: String, identifier: String = UpdateInstallerTests.bundleIdentifier) throws -> URL {
        let app = folder.appending(path: "\(Self.appName).app", directoryHint: .isDirectory)
        let macOS = app.appending(components: "Contents", "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": Self.appName,
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appending(components: "Contents", "Info.plist"))
        let executable = macOS.appending(path: Self.appName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    /// Read from the Info.plist directly: `Bundle` caches bundles by path.
    private func version(ofAppAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appending(components: "Contents", "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    private func folder(_ name: String, in temporary: TemporaryDirectory) throws -> URL {
        let url = temporary.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Replacing and rolling back

    @Test func replaceMovesTheOldAppToBackupsAndTheNewOneInPlace() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installed = try makeApp(in: folder("Applications", in: temporary), version: "0.5.0")
        let staged = try makeApp(in: folder("staged", in: temporary), version: "0.6.0")
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")))

        let backup = try installer.replace(installedApp: installed, with: staged, now: Date(timeIntervalSince1970: 0))

        #expect(version(ofAppAt: installed) == "0.6.0")
        #expect(version(ofAppAt: backup) == "0.5.0")
        #expect(backup.deletingLastPathComponent().standardizedFileURL == installer.directories.backups.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func failedReplaceRollsBackToTheOldApp() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installed = try makeApp(in: folder("Applications", in: temporary), version: "0.5.0")
        let missing = temporary.url.appending(path: "staged/\(Self.appName).app", directoryHint: .isDirectory)
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")))

        #expect(throws: UpdateInstallError.self) { try installer.replace(installedApp: installed, with: missing) }

        #expect(version(ofAppAt: installed) == "0.5.0")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: installer.directories.backups.path)) ?? []
        #expect(backups.isEmpty)
    }

    @Test func installLocationProblemsAreReported() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let installed = try makeApp(in: folder("Applications", in: temporary), version: "0.5.0")

        #expect(UpdateInstaller.installLocationProblem(for: installed) == nil)
        #expect(UpdateInstaller.installLocationProblem(for: temporary.url.appending(path: "Nowhere.app")) != nil)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1234/d/\(Self.appName).app")
        #expect(UpdateInstaller.installLocationProblem(for: translocated)?.contains("Applications folder") == true)
    }

    // MARK: - Checking the download and the staged app

    @Test func stagedAppMustBeThisAppInTheReleasedVersion() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let expected = try #require(SemanticVersion("v0.6.0"))
        let good = try makeApp(in: folder("good", in: temporary), version: "0.6.0")
        let otherApp = try makeApp(in: folder("other", in: temporary), version: "0.6.0", identifier: "com.example.other")
        let oldVersion = try makeApp(in: folder("old", in: temporary), version: "0.5.0")
        let noExecutable = try makeApp(in: folder("broken", in: temporary), version: "0.6.0")
        try FileManager.default.removeItem(at: noExecutable.appending(components: "Contents", "MacOS", Self.appName))

        #expect(throws: Never.self) { try UpdateInstaller.validateStagedApp(good, bundleIdentifier: Self.bundleIdentifier, version: expected) }
        #expect(throws: UpdateInstallError.wrongApp("com.example.other")) {
            try UpdateInstaller.validateStagedApp(otherApp, bundleIdentifier: Self.bundleIdentifier, version: expected)
        }
        #expect(throws: UpdateInstallError.versionMismatch(expected: "0.6.0", found: "0.5.0")) {
            try UpdateInstaller.validateStagedApp(oldVersion, bundleIdentifier: Self.bundleIdentifier, version: expected)
        }
        #expect(throws: UpdateInstallError.appNotFound) {
            try UpdateInstaller.validateStagedApp(noExecutable, bundleIdentifier: Self.bundleIdentifier, version: expected)
        }
    }

    @Test func downloadIsCheckedAgainstSizeAndChecksum() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "update.dmg")
        try Data("disk image".utf8).write(to: file)
        let sha = try UpdateInstaller.sha256(ofFileAt: file)
        let url = URL(string: "https://example.com/update.dmg")!

        #expect(sha == "0bb2f0f3ed953c47d835a7adaefd95afa328e30a5c80fdce417dd12b014ad602")
        #expect(throws: Never.self) { try UpdateInstaller.verify(file, against: ReleaseAsset(name: "u", downloadURL: url, size: 10, digest: "sha256:\(sha)")) }
        #expect(throws: UpdateInstallError.sizeMismatch(expected: 11, actual: 10)) {
            try UpdateInstaller.verify(file, against: ReleaseAsset(name: "u", downloadURL: url, size: 11))
        }
        #expect(throws: UpdateInstallError.checksumMismatch) {
            try UpdateInstaller.verify(file, against: ReleaseAsset(name: "u", downloadURL: url, size: 10, digest: "sha256:\(String(repeating: "0", count: 64))"))
        }
    }

    @Test func downloadsOverHTTPSOnlyAndVerifiesTheFile() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let body = Data(repeating: 0x5A, count: 4096)
        let bodyFile = temporary.url.appending(path: "body")
        try body.write(to: bodyFile)
        let sha = try UpdateInstaller.sha256(ofFileAt: bodyFile)
        let url = StubURLProtocol.register(.init(body: body), fileName: "Cybokron-Limit-Guard-0.6.0-universal.dmg")
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")))

        let downloaded = try await installer.download(
            ReleaseAsset(name: "../Cybokron-Limit-Guard-0.6.0-universal.dmg", downloadURL: url, size: body.count, digest: "sha256:\(sha)"),
            session: StubURLProtocol.makeSession()
        )

        #expect(downloaded.lastPathComponent == "Cybokron-Limit-Guard-0.6.0-universal.dmg")
        #expect(downloaded.deletingLastPathComponent().standardizedFileURL == installer.directories.downloads.standardizedFileURL)
        #expect(try Data(contentsOf: downloaded) == body)

        await #expect(throws: UpdateInstallError.insecureDownloadURL("http://example.com/x-universal.dmg")) {
            try await installer.download(ReleaseAsset(name: "x-universal.dmg", downloadURL: URL(string: "http://example.com/x-universal.dmg")!, size: 1))
        }
        #expect(UpdateInstaller.isAllowedDownloadURL(URL(string: "http://127.0.0.1:8765/x.dmg")!))
        #expect(!UpdateInstaller.isAllowedDownloadURL(URL(string: "file:///tmp/x.dmg")!))
    }

    // MARK: - Staging from the disk image

    @Test func stagingCopiesTheAppOutOfTheMountedImage() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let imageApp = try makeApp(in: folder("image", in: temporary), version: "0.6.0")
        let tools = FakeDiskImageTools(diskImageApp: imageApp)
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: tools)

        let staged = try await installer.stageApp(fromDiskImage: temporary.url.appending(path: "update.dmg"), appName: Self.appName, expectedTeamIdentifier: nil)

        #expect(staged.lastPathComponent == "\(Self.appName).app")
        #expect(version(ofAppAt: staged) == "0.6.0")
        let attach = try #require(tools.calls.first)
        #expect(Array(attach.prefix(5)) == ["hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen"])
        #expect(tools.calls.contains { $0.starts(with: ["hdiutil", "detach"]) })
        // The mount point is gone once the image is detached.
        let mounts = (try? FileManager.default.contentsOfDirectory(atPath: installer.directories.mounts.path)) ?? []
        #expect(mounts.isEmpty)

        let empty = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates2")), tools: FakeDiskImageTools(diskImageApp: nil))
        await #expect(throws: UpdateInstallError.appNotFound) {
            try await empty.stageApp(fromDiskImage: temporary.url.appending(path: "update.dmg"), appName: Self.appName, expectedTeamIdentifier: nil)
        }
    }

    @Test func realDiskImageIsMountedCopiedAndDetached() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let source = try folder("dmg-source", in: temporary)
        _ = try makeApp(in: source, version: "0.6.0")
        try FileManager.default.createSymbolicLink(at: source.appending(path: "Applications"), withDestinationURL: URL(fileURLWithPath: "/Applications"))
        let image = temporary.url.appending(path: "test-universal.dmg")
        let created = try await SystemToolRunner().run(UpdateInstaller.hdiutil, arguments: [
            "create", "-quiet", "-volname", "Cybokron Update Test", "-srcfolder", source.path, "-format", "UDZO", "-ov", image.path,
        ])
        try #require(created.succeeded, "hdiutil create: \(created.output)")
        // Attaching can fail transiently on a busy machine ("Resource temporarily unavailable").
        let installer = UpdateInstaller(
            directories: UpdateDirectories(root: temporary.url.appending(path: "updates")),
            tools: DiskImageAttachRetryingRunner()
        )

        let staged = try await installer.stageApp(fromDiskImage: image, appName: Self.appName, expectedTeamIdentifier: nil)

        #expect(version(ofAppAt: staged) == "0.6.0")
        #expect(throws: Never.self) {
            try UpdateInstaller.validateStagedApp(staged, bundleIdentifier: Self.bundleIdentifier, version: SemanticVersion(major: 0, minor: 6, patch: 0))
        }
        let mounts = (try? FileManager.default.contentsOfDirectory(atPath: installer.directories.mounts.path)) ?? []
        #expect(mounts.isEmpty)
    }

    // MARK: - Relaunch and cleanup

    @Test func relaunchScriptRefusesAnEmptyAppPath() async throws {
        // Without a path, `open` would show a Finder window; the script stops before waiting.
        let result = try await SystemToolRunner().run(UpdateInstaller.shell, arguments: ["-c", UpdateInstaller.relaunchScript, "cybokron-relaunch", "1", "", ""])
        #expect(result.status == 64)
    }

    @Test func relaunchPassesPathsAsArguments() {
        let app = URL(fileURLWithPath: "/Applications/\(Self.appName).app")
        let backup = URL(fileURLWithPath: "/tmp/it's \"odd\"/\(Self.appName).app")

        let arguments = UpdateInstaller.relaunchArguments(processID: 4242, appURL: app, backupURL: backup)

        #expect(arguments.count == 6)
        #expect(arguments[0] == "-c")
        #expect(Array(arguments[2...]) == ["cybokron-relaunch", "4242", app.path, backup.path])
        #expect(!UpdateInstaller.relaunchScript.contains(app.path))
        #expect(UpdateInstaller.relaunchArguments(processID: 1, appURL: app, backupURL: nil).last == "")
    }

    @Test func leftoversAreRemovedButTheNewestBackupIsKept() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let directories = UpdateDirectories(root: temporary.url.appending(path: "updates"))
        let fileManager = FileManager.default
        for folder in [directories.downloads, directories.staging, directories.mounts.appending(path: "stale"), directories.backups] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("dmg".utf8).write(to: directories.downloads.appending(path: "old.dmg"))
        let older = directories.backups.appending(path: "\(Self.appName) 20261001-000000.app")
        let newer = directories.backups.appending(path: "\(Self.appName) 20261017-000000.app")
        try fileManager.createDirectory(at: older, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newer, withIntermediateDirectories: true)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)

        UpdateInstaller(directories: directories).removeLeftovers(keepingBackups: 1)

        #expect(!fileManager.fileExists(atPath: directories.downloads.path))
        #expect(!fileManager.fileExists(atPath: directories.staging.path))
        #expect(!fileManager.fileExists(atPath: directories.mounts.path))
        #expect(fileManager.fileExists(atPath: newer.path))
        #expect(!fileManager.fileExists(atPath: older.path))
    }

    // MARK: - Remembered state and settings

    @Test func updateStateSurvivesARoundTrip() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let persistence = JSONFileUpdateStatePersistence(fileURL: temporary.url.appending(path: "update-state.json"))
        #expect(persistence.load() == UpdateState())

        let state = UpdateState(lastCheckDate: Date(timeIntervalSince1970: 1_800_000_000), skippedVersions: ["0.6.0"])
        try persistence.save(state)
        #expect(persistence.load() == state)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
        #expect(object?["lastCheckDate"] as? Double == 1_800_000_000)

        try Data("not json".utf8).write(to: persistence.fileURL)
        #expect(persistence.load() == UpdateState())
    }

    @Test func automaticChecksSettingIsSavedWithTheUpdateState() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let persistence = JSONFileUpdateStatePersistence(fileURL: temporary.url.appending(path: "update-state.json"))
        #expect(UpdateState().automaticallyChecks)

        var state = UpdateState()
        state.automaticallyChecks = false
        try persistence.save(state)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any]
        #expect(object?["automaticallyChecks"] as? Bool == false)
        #expect(persistence.load().automaticallyChecks == false)
        // Files without the key keep checking.
        try Data(#"{"formatVersion": 1, "lastCheckDate": 1800000000}"#.utf8).write(to: persistence.fileURL)
        #expect(persistence.load().automaticallyChecks)
    }
}

/// Going back from Other Versions…: every data file is copied aside first
/// (`<name>.pre-downgrade-<timestamp>.json`, `makePreDowngradeCopies`), and only going back.
@Suite("Update installer: copies of the data files before going back")
struct PreDowngradeCopyTests {
    private static func version(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

    @Test func appliesOnlyGoingBack() {
        #expect(DowngradeProtection.applies(installing: Self.version("0.1.0"), over: Self.version("0.1.1")))
        #expect(DowngradeProtection.applies(installing: Self.version("0.1.0"), over: Self.version("0.2.0")))
        #expect(DowngradeProtection.applies(installing: Self.version("0.1.0"), over: nil))
        #expect(!DowngradeProtection.applies(installing: Self.version("0.1.1"), over: Self.version("0.1.1")))
        #expect(!DowngradeProtection.applies(installing: Self.version("0.2.0"), over: Self.version("0.1.1")))
    }

    @Test func releaseHistoryStartsAtTheFirstRelease() {
        #expect(ReleaseHistory.minimumSecurityVersion == Self.version("0.1.0"))
        #expect(!ReleaseHistory.lacksSecurityFixes(Self.version("0.1.0")))
        #expect(ReleaseHistory.lacksSecurityFixes(Self.version("0.0.9")))
    }

    @Test func copiesEveryDataFileAsideGoingBack() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        try Data(#"{"schemaVersion": 1}"#.utf8).write(to: temporary.url.appending(path: "settings.json"))
        try Data(#"{"schemaVersion": 1, "x": 2}"#.utf8).write(to: temporary.url.appending(path: "state.json"))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = DowngradeProtection.timestamp(when)

        let copied = try DowngradeProtection.preserveCopies(
            in: temporary.url, installing: Self.version("0.1.0"), over: Self.version("0.2.0"), now: when
        )

        #expect(copied)
        let settingsCopy = temporary.url.appending(path: "settings.pre-downgrade-\(stamp).json")
        let stateCopy = temporary.url.appending(path: "state.pre-downgrade-\(stamp).json")
        #expect(try Data(contentsOf: settingsCopy) == Data(contentsOf: temporary.url.appending(path: "settings.json")))
        #expect(try Data(contentsOf: stateCopy) == Data(contentsOf: temporary.url.appending(path: "state.json")))
        #expect(stamp.count == "yyyyMMdd-HHmmss".count)
    }

    @Test func makesNoCopyGoingUpOrStayingPut() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        try Data(#"{"schemaVersion": 1}"#.utf8).write(to: temporary.url.appending(path: "settings.json"))

        #expect(try !DowngradeProtection.preserveCopies(in: temporary.url, installing: Self.version("0.2.0"), over: Self.version("0.1.0")))
        #expect(try !DowngradeProtection.preserveCopies(in: temporary.url, installing: Self.version("0.1.0"), over: Self.version("0.1.0")))
        let names = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path)
        #expect(names == ["settings.json"])
    }

    @Test func aMissingDataFolderHasNothingToCopy() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let missing = temporary.url.appending(path: "never-created", directoryHint: .isDirectory)
        #expect(try !DowngradeProtection.preserveCopies(in: missing, installing: Self.version("0.1.0"), over: Self.version("0.2.0")))
    }

    @Test func copyingTwiceInTheSameSecondReplacesTheCopy() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "settings.json")
        try Data(#"{"schemaVersion": 1, "a": 1}"#.utf8).write(to: file)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try DowngradeProtection.preserveCopies(in: temporary.url, installing: Self.version("0.1.0"), over: Self.version("0.2.0"), now: when)
        try Data(#"{"schemaVersion": 1, "a": 2}"#.utf8).write(to: file)
        try DowngradeProtection.preserveCopies(in: temporary.url, installing: Self.version("0.1.0"), over: Self.version("0.2.0"), now: when)

        let copy = temporary.url.appending(path: "settings.pre-downgrade-\(DowngradeProtection.timestamp(when)).json")
        #expect(try String(contentsOf: copy, encoding: .utf8).contains(#""a": 2"#))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).count == 2)
    }

    /// A copy target that can't be replaced (a non-empty directory where the copy goes).
    private func blockedFolder() throws -> (TemporaryDirectory, now: Date) {
        let temporary = try TemporaryDirectory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try Data(#"{"schemaVersion": 1}"#.utf8).write(to: temporary.url.appending(path: "settings.json"))
        let blocker = temporary.url.appending(path: "settings.pre-downgrade-\(DowngradeProtection.timestamp(now)).json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocker.appending(path: "inner"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocker.path)
        return (temporary, now)
    }

    private func unblock(_ temporary: TemporaryDirectory) {
        let blocker = (try? FileManager.default.contentsOfDirectory(at: temporary.url, includingPropertiesForKeys: nil)) ?? []
        for url in blocker { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        temporary.remove()
    }

    @Test func aFailingCopyThrows() throws {
        let (temporary, now) = try blockedFolder()
        defer { unblock(temporary) }
        #expect(throws: (any Error).self) {
            try DowngradeProtection.preserveCopies(in: temporary.url, installing: Self.version("0.1.0"), over: Self.version("0.2.0"), now: now)
        }
    }

    @Test func aFailingCopyPreventsTheReplace() async throws {
        let (temporary, now) = try blockedFolder()
        defer { unblock(temporary) }
        var replaced = false
        await #expect(throws: (any Error).self) {
            try await DowngradeProtection.replacing(in: temporary.url, installing: Self.version("0.1.0"), over: Self.version("0.2.0"), now: now) {
                replaced = true
            }
        }
        #expect(!replaced)
    }

    @Test func replaceRunsAfterTheCopies() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        try Data(#"{"schemaVersion": 1}"#.utf8).write(to: temporary.url.appending(path: "settings.json"))
        var copiesExistedAtReplace = false
        try await DowngradeProtection.replacing(in: temporary.url, installing: Self.version("0.1.0"), over: Self.version("0.2.0")) {
            copiesExistedAtReplace = ((try? FileManager.default.contentsOfDirectory(atPath: temporary.url.path)) ?? []).count == 2
        }
        #expect(copiesExistedAtReplace)
    }
}
