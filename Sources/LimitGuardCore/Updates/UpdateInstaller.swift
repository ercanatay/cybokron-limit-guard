import CryptoKit
import Foundation

/// Why downloading or installing an update failed.
public enum UpdateInstallError: LocalizedError, Equatable, Sendable {
    /// The download address isn't HTTPS (plain HTTP is allowed only for this Mac, for testing).
    case insecureDownloadURL(String)
    case downloadFailed(String)
    /// The downloaded file doesn't have the size GitHub reported.
    case sizeMismatch(expected: Int, actual: Int)
    /// The downloaded file doesn't match GitHub's SHA-256 checksum.
    case checksumMismatch
    case mountFailed(String)
    /// The disk image holds no app (or more than one and none with the expected name).
    case appNotFound
    /// The app in the disk image isn't this app.
    case wrongApp(String)
    /// The app in the disk image has another version than the release it came from.
    case versionMismatch(expected: String, found: String)
    /// The staged app's code signature is broken or missing (`codesign --verify --strict` failed).
    case invalidSignature(String)
    /// The staged app is signed with a Developer ID of another team than the running app.
    case wrongSigner(found: String, expected: String)
    /// The running app can't be replaced where it is.
    case locationNotWritable(String)
    /// Putting the new app in place failed; the previous app was put back.
    case replaceFailed(String)
    /// Putting the new app in place failed and so did putting the previous one back; it's kept at
    /// the given path.
    case rollbackFailed(backupPath: String)

    public var errorDescription: String? {
        switch self {
        case .insecureDownloadURL(let url):
            return Localization.format("core.update.install.insecureURL", "The update's download address isn't secure (%@).", url)
        case .downloadFailed(let reason):
            return Localization.format("core.update.install.downloadFailed", "The update couldn't be downloaded: %@", reason)
        case .sizeMismatch(let expected, let actual):
            return Localization.format("core.update.install.sizeMismatch", "The downloaded update is incomplete (%1$ld of %2$ld bytes).", actual, expected)
        case .checksumMismatch:
            return Localization.string("core.update.install.checksum", "The downloaded update doesn't match its published checksum, so it wasn't installed.")
        case .mountFailed(let reason):
            return Localization.format("core.update.install.mountFailed", "The update's disk image couldn't be opened: %@", reason)
        case .appNotFound:
            return Localization.string("core.update.install.appNotFound", "The update's disk image doesn't contain the app.")
        case .wrongApp(let identifier):
            return Localization.format("core.update.install.wrongApp", "The update's disk image contains another app (%@).", identifier)
        case .versionMismatch(let expected, let found):
            return Localization.format("core.update.install.versionMismatch", "The downloaded app is version %1$@, but the release is %2$@.", found, expected)
        case .invalidSignature(let reason):
            return Localization.format("core.update.install.invalidSignature", "The downloaded app's code signature isn't valid, so it wasn't installed: %@", reason)
        case .wrongSigner(let found, let expected):
            return Localization.format("core.update.install.wrongSigner", "The downloaded app is signed by another developer (team %1$@ instead of %2$@), so it wasn't installed.", found, expected)
        case .locationNotWritable(let reason):
            return reason
        case .replaceFailed(let reason):
            return Localization.format("core.update.install.replaceFailed", "The new version couldn't be put in place, so the current one was kept: %@", reason)
        case .rollbackFailed(let backupPath):
            return Localization.format("core.update.install.rollbackFailed", "The update failed and the previous version couldn't be put back. It's kept at %@.", backupPath)
        }
    }
}

/// The updater's working folders, by default under
/// `~/Library/Application Support/Cybokron Limit Guard/updates/`.
public struct UpdateDirectories: Sendable {
    public static var defaultRoot: URL { defaultRoot(in: DataDirectory.url) }

    static func defaultRoot(in directory: URL) -> URL {
        directory.appending(path: "updates", directoryHint: .isDirectory)
    }

    public let root: URL

    public init(root: URL = UpdateDirectories.defaultRoot) {
        self.root = root
    }

    /// Downloaded disk images.
    public var downloads: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
    /// The new app, copied out of the disk image before it replaces the running one.
    public var staging: URL { root.appending(path: "staging", directoryHint: .isDirectory) }
    /// Previous versions, moved aside during an update and used to roll back.
    public var backups: URL { root.appending(path: "backups", directoryHint: .isDirectory) }
    /// Mount points of the disk images while the app is copied out.
    public var mounts: URL { root.appending(path: "mounts", directoryHint: .isDirectory) }
}

/// Downloads a release's disk image and swaps the running app for the one inside:
///
/// 1. `download` saves the disk image in `downloads/` and checks its size and SHA-256 checksum.
/// 2. `stageApp` checks the disk image's own signature when the running app is Developer ID signed
///    (`verifyDiskImageSignature`, before anything is mounted), then mounts it read-only and hidden
///    (`hdiutil attach -readonly -nobrowse`), copies the app to `staging/` with `ditto`, and
///    detaches it again.
/// 3. `validateStagedApp` checks that the copy is this app, in the release's version.
/// 4. `verifySignature` checks that the copy's code signature is intact and — when the running app
///    is Developer ID signed — that it's a Developer ID signature of the running app's team.
/// 5. `replace` moves the running app to `backups/` and the new one into its place; if that fails,
///    the previous app is moved back.
/// 6. `relaunchArguments` starts the new version once this process has quit, and rolls back to the
///    backup if it can't be opened.
///
/// Gatekeeper doesn't check the new version: nothing marks the downloaded disk image or the copied
/// app as quarantined, so macOS opens it without assessing it. The SHA-256 checksum GitHub
/// publishes for the disk image and the checks above are what keep a damaged or swapped download
/// out.
public struct UpdateInstaller: Sendable {
    public static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    public static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    public static let shell = URL(fileURLWithPath: "/bin/sh")

    /// Set to stop an installation after the new app is staged and checked, without replacing or
    /// relaunching anything (to try the download path). Development builds only
    /// (`DevelopmentOverrides`).
    public static let dryRunVariable = "CYBOKRON_UPDATE_DRY_RUN"

    public let directories: UpdateDirectories
    private let tools: ToolRunning

    public init(directories: UpdateDirectories = UpdateDirectories(), tools: ToolRunning = SystemToolRunner()) {
        self.directories = directories
        self.tools = tools
    }

    // MARK: - Where the app runs

    /// Why the app at `bundleURL` can't be replaced in place, `nil` when it can: macOS runs it from a
    /// randomized read-only copy (App Translocation), it's on a read-only volume, or its folder isn't
    /// writable for this user.
    public static func installLocationProblem(for bundleURL: URL, fileManager: FileManager = .default) -> String? {
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") {
            return Localization.string("core.update.location.translocated", "macOS runs this copy from a temporary read-only location. Move the app to your Applications folder, open it from there, and try again.")
        }
        guard fileManager.fileExists(atPath: path) else {
            return Localization.format("core.update.location.notFound", "The running app wasn't found at %@.", path)
        }
        if (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return Localization.string("core.update.location.readOnly", "The app runs from a read-only volume, such as its disk image. Copy it to your Applications folder first.")
        }
        let folder = bundleURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: folder) else {
            return Localization.format("core.update.location.noPermission", "You don't have permission to replace the app in “%@”. Download the new version from the releases page instead.", folder)
        }
        return nil
    }

    // MARK: - Download

    /// HTTPS anywhere; plain HTTP only to this Mac (a local test server). See
    /// `LinkPolicy.isSecureOrLocal`.
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        LinkPolicy.isSecureOrLocal(url)
    }

    /// Downloads `asset` to `downloads/` and checks it with `verify`. Returns the file's location.
    public func download(
        _ asset: ReleaseAsset,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard Self.isAllowedDownloadURL(asset.downloadURL) else {
            throw UpdateInstallError.insecureDownloadURL(asset.downloadURL.absoluteString)
        }
        let fileManager = FileManager.default
        let destination = directories.downloads.appending(path: Self.safeFileName(asset.name), directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: directories.downloads, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        } catch {
            throw UpdateInstallError.downloadFailed(error.localizedDescription)
        }

        var request = URLRequest(url: asset.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let box = DownloadTaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    if let error {
                        let cancelled = (error as? URLError)?.code == .cancelled
                        continuation.resume(throwing: cancelled ? CancellationError() : UpdateInstallError.downloadFailed(error.localizedDescription))
                        return
                    }
                    guard let http = response as? HTTPURLResponse, let location else {
                        continuation.resume(throwing: UpdateInstallError.downloadFailed(Localization.string("core.update.install.noFile", "The server sent no file.")))
                        return
                    }
                    guard http.statusCode == 200 else {
                        continuation.resume(throwing: UpdateInstallError.downloadFailed(Localization.format("core.update.install.httpStatus", "HTTP status %ld.", http.statusCode)))
                        return
                    }
                    // Redirects are followed; they must stay secure too.
                    if let finalURL = http.url, !Self.isAllowedDownloadURL(finalURL) {
                        continuation.resume(throwing: UpdateInstallError.insecureDownloadURL(finalURL.absoluteString))
                        return
                    }
                    do {
                        // The temporary file is deleted once this handler returns.
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: UpdateInstallError.downloadFailed(error.localizedDescription))
                    }
                }
                box.start(task, progress: progress)
            }
        } onCancel: {
            box.cancel()
        }
        try Self.verify(destination, against: asset)
        return destination
    }

    /// Checks the downloaded file against the size and SHA-256 checksum GitHub published for it
    /// (each only when known).
    public static func verify(_ fileURL: URL, against asset: ReleaseAsset) throws {
        if asset.size > 0 {
            let actual = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? -1
            guard actual == asset.size else {
                throw UpdateInstallError.sizeMismatch(expected: asset.size, actual: max(actual, 0))
            }
        }
        if let expected = asset.sha256 {
            let actual: String
            do {
                actual = try sha256(ofFileAt: fileURL)
            } catch {
                throw UpdateInstallError.downloadFailed(error.localizedDescription)
            }
            guard actual == expected else { throw UpdateInstallError.checksumMismatch }
        }
    }

    /// Lowercase hex SHA-256 of a file, read in chunks.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Staging

    /// Mounts the disk image read-only without showing it in the Finder, copies the app named
    /// `appName` (or its only app) to `staging/`, and detaches the image. Returns the staged copy.
    ///
    /// When `expectedTeamIdentifier` is known (the running app is Developer ID signed), the disk
    /// image's signature is checked first (`verifyDiskImageSignature`); one that isn't a Developer
    /// ID signature of that team is never mounted. `nil` (a running copy signed ad hoc, as up to
    /// 0.6.2) mounts it unchecked, as before.
    public func stageApp(fromDiskImage diskImage: URL, appName: String, expectedTeamIdentifier: String?) async throws -> URL {
        if let expectedTeamIdentifier {
            try await verifyDiskImageSignature(diskImage, expectedTeamIdentifier: expectedTeamIdentifier)
        }
        let fileManager = FileManager.default
        let mountPoint = directories.mounts.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            if fileManager.fileExists(atPath: directories.staging.path) {
                try fileManager.removeItem(at: directories.staging)
            }
            try fileManager.createDirectory(at: directories.staging, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            throw UpdateInstallError.mountFailed(error.localizedDescription)
        }

        let attach = try await tools.run(Self.hdiutil, arguments: [
            "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, diskImage.path,
        ])
        guard attach.succeeded else {
            try? fileManager.removeItem(at: mountPoint)
            throw UpdateInstallError.mountFailed(attach.output.isEmpty ? "hdiutil exited with \(attach.status)" : attach.output)
        }

        let result: Result<URL, Error>
        do {
            guard let source = Self.findApp(in: mountPoint, named: appName, fileManager: fileManager) else {
                throw UpdateInstallError.appNotFound
            }
            let staged = directories.staging.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
            let copy = try await tools.run(Self.ditto, arguments: [source.path, staged.path])
            guard copy.succeeded else {
                let detail = copy.output.isEmpty ? "ditto exited with \(copy.status)" : copy.output
                throw UpdateInstallError.mountFailed(Localization.format("core.update.install.copyFailed", "Copying the app failed: %@", detail))
            }
            result = .success(staged)
        } catch {
            result = .failure(error)
        }
        await detach(mountPoint)
        return try result.get()
    }

    /// The `.app` folder in `directory` named `name` (with or without the extension); otherwise its
    /// only app. Links (such as the Applications alias) and hidden items don't count.
    static func findApp(in directory: URL, named name: String, fileManager: FileManager = .default) -> URL? {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let apps = entries.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return url.pathExtension.lowercased() == "app" && values?.isDirectory == true && values?.isSymbolicLink != true
        }
        let wanted = name.hasSuffix(".app") ? name : "\(name).app"
        return apps.first { $0.lastPathComponent == wanted } ?? (apps.count == 1 ? apps.first : nil)
    }

    private func detach(_ mountPoint: URL) async {
        let detached = (try? await tools.run(Self.hdiutil, arguments: ["detach", mountPoint.path, "-quiet"]))?.succeeded ?? false
        if !detached {
            _ = try? await tools.run(Self.hdiutil, arguments: ["detach", mountPoint.path, "-force", "-quiet"])
        }
        Self.removeEmptyDirectory(mountPoint)
    }

    /// Checks that the staged app is this app (same bundle identifier), in `version`, with its
    /// executable in place.
    public static func validateStagedApp(_ appURL: URL, bundleIdentifier: String, version: SemanticVersion) throws {
        let contents = appURL.appending(path: "Contents", directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: contents.appending(path: "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw UpdateInstallError.appNotFound
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? "no identifier"
        guard identifier == bundleIdentifier else {
            throw UpdateInstallError.wrongApp(identifier)
        }
        let found = info["CFBundleShortVersionString"] as? String ?? "unknown"
        guard SemanticVersion(found) == version else {
            throw UpdateInstallError.versionMismatch(expected: version.description, found: found)
        }
        guard let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: contents.appending(components: "MacOS", executable).path)
        else {
            throw UpdateInstallError.appNotFound
        }
    }

    // MARK: - Code signature

    /// `codesign`'s exit status when the code is validly signed but doesn't satisfy the requirement
    /// given with `-R`.
    static let requirementUnsatisfiedStatus: Int32 = 3

    /// The code requirement a Developer ID signature of `teamIdentifier` satisfies: a certificate
    /// chain anchored at Apple, issued by the Developer ID certification authority, with a Developer
    /// ID Application leaf whose organizational unit is the team. With `identifier`, the code's
    /// signing identifier must be that too (the app's bundle identifier); disk images are signed
    /// under their file name, so theirs isn't pinned.
    public static func developerIDRequirement(teamIdentifier: String, identifier: String? = nil) -> String {
        var clauses = ["anchor apple generic"]
        if let identifier {
            clauses.append("identifier \"\(identifier)\"")
        }
        clauses += [
            "certificate 1[field.1.2.840.113635.100.6.2.6] exists",
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
        ]
        return clauses.joined(separator: " and ")
    }

    /// The team later versions must be signed by. Release builds record their team in Info.plist
    /// (`pinned`), so the check never depends on reading the running app's signature; any other
    /// copy falls back to the team of its own signature (`running`), `nil` when it's signed ad hoc.
    /// A malformed pinned value is still returned, and refused when it's checked.
    public static func expectedTeamIdentifier(pinned: String?, running: String?) -> String? {
        if let pinned, !pinned.isEmpty { return pinned }
        return running
    }

    /// Apple team identifiers: ten uppercase letters and digits. Anything else is refused before
    /// it's put into a code requirement.
    static func isWellFormedTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Bundle identifiers: letters, digits, hyphens and dots, as Apple allows them.
    static func isWellFormedBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "."
        }
    }

    /// Checks the staged app's code signature with `codesign --verify --strict`: it must be signed,
    /// and nothing in the bundle may have changed since.
    ///
    /// When `expectedTeamIdentifier` — the running app's team — is known, the app must also satisfy
    /// `developerIDRequirement` for that team and `bundleIdentifier` (`codesign --verify --strict
    /// -R`): an ad hoc signature, or a Developer ID one of another team, is refused, so a Developer
    /// ID signed copy never updates to code anyone else signed. A running copy signed ad hoc (up to
    /// 0.6.2) has no team to hold the update to, so it accepts any intact signature, as before.
    public func verifySignature(ofStagedApp appURL: URL, bundleIdentifier: String, expectedTeamIdentifier: String?) async throws {
        try await verifyIntactSignature(of: appURL)
        guard let expectedTeamIdentifier else { return }
        guard Self.isWellFormedBundleIdentifier(bundleIdentifier) else {
            throw UpdateInstallError.invalidSignature("unexpected bundle identifier “\(bundleIdentifier)”")
        }
        try await verifyDeveloperIDSignature(of: appURL, identifier: bundleIdentifier, expectedTeamIdentifier: expectedTeamIdentifier)
    }

    /// Checks a downloaded disk image's signature before it's mounted: it must be intact and a
    /// Developer ID signature of `expectedTeamIdentifier` (`developerIDRequirement`). Releases from
    /// 0.6.3 on are signed and notarized this way.
    public func verifyDiskImageSignature(_ diskImage: URL, expectedTeamIdentifier: String) async throws {
        try await verifyIntactSignature(of: diskImage)
        try await verifyDeveloperIDSignature(of: diskImage, identifier: nil, expectedTeamIdentifier: expectedTeamIdentifier)
    }

    /// `codesign --verify --strict`: signed, and unchanged since.
    private func verifyIntactSignature(of url: URL) async throws {
        let verification = try await tools.run(SystemTools.codesign, arguments: ["--verify", "--strict", url.path])
        guard verification.succeeded else {
            throw UpdateInstallError.invalidSignature(Self.describe(verification))
        }
    }

    /// `codesign --verify --strict -R=<developerIDRequirement>`. When the requirement isn't met
    /// (exit status 3), the signature's description says which error fits: an ad hoc signature
    /// or another team is `wrongSigner`. When codesign can't evaluate the requirement at all (any
    /// other failure), the signature is refused as `invalidSignature`.
    private func verifyDeveloperIDSignature(of url: URL, identifier: String?, expectedTeamIdentifier: String) async throws {
        guard Self.isWellFormedTeamIdentifier(expectedTeamIdentifier) else {
            throw UpdateInstallError.invalidSignature("unexpected team identifier “\(expectedTeamIdentifier)”")
        }
        let requirement = Self.developerIDRequirement(teamIdentifier: expectedTeamIdentifier, identifier: identifier)
        let check = try await tools.run(SystemTools.codesign, arguments: ["--verify", "--strict", "-R", "=\(requirement)", url.path])
        if check.succeeded { return }
        let signature = await signature(ofAppAt: url)
        if check.status == Self.requirementUnsatisfiedStatus {
            if let team = signature?.signingTeam, team == expectedTeamIdentifier {
                // Right team, but not a Developer ID Application certificate or another identifier.
                throw UpdateInstallError.invalidSignature(Self.describe(check))
            }
            throw UpdateInstallError.wrongSigner(found: signature?.teamIdentifier ?? "none", expected: expectedTeamIdentifier)
        }
        // The requirement couldn't be evaluated: nothing vouches for the signature, so it's refused.
        throw UpdateInstallError.invalidSignature(Self.describe(check))
    }

    private static func describe(_ result: ToolResult) -> String {
        result.output.isEmpty ? "codesign exited with \(result.status)" : result.output
    }

    /// What `codesign` reports about the signature of the app (or disk image) at `appURL`; `nil`
    /// when it can't tell (no signature, or codesign failed).
    public func signature(ofAppAt appURL: URL) async -> CodeSignature? {
        guard let requirement = try? await tools.run(SystemTools.codesign, arguments: ["-d", "-r-", appURL.path]), requirement.succeeded,
              let details = try? await tools.run(SystemTools.codesign, arguments: ["-dv", "--verbose=2", appURL.path]), details.succeeded
        else { return nil }
        return CodeSignature(requirementOutput: requirement.output, detailsOutput: details.output)
    }

    // MARK: - Replacing

    /// Moves `installedApp` to `backups/` and `stagedApp` into its place. When the second step fails,
    /// the previous app is moved back before the error is thrown. Returns the backup's location.
    @discardableResult
    public func replace(installedApp: URL, with stagedApp: URL, now: Date = Date()) throws -> URL {
        if let problem = Self.installLocationProblem(for: installedApp) {
            throw UpdateInstallError.locationNotWritable(problem)
        }
        let fileManager = FileManager.default
        let name = installedApp.deletingPathExtension().lastPathComponent
        let backup = directories.backups.appending(path: "\(name) \(Self.backupTimestampFormatter.string(from: now)).app", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: directories.backups, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try fileManager.moveItem(at: installedApp, to: backup)
        } catch {
            throw UpdateInstallError.replaceFailed(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: stagedApp, to: installedApp)
        } catch {
            let reason = error.localizedDescription
            do {
                if fileManager.fileExists(atPath: installedApp.path) {
                    try fileManager.removeItem(at: installedApp)
                }
                try fileManager.moveItem(at: backup, to: installedApp)
            } catch {
                throw UpdateInstallError.rollbackFailed(backupPath: backup.path)
            }
            throw UpdateInstallError.replaceFailed(reason)
        }
        return backup
    }

    // MARK: - Relaunching

    /// Waits (up to a minute) for the old process to quit, then opens the new app; if it can't be
    /// opened, puts the backup back and opens that. Arguments: process ID, app path, backup path.
    /// An empty app path ends it right away (`open ""` would open a Finder window).
    public static let relaunchScript = """
        pid="$1"; app="$2"; backup="$3"
        [ -n "$app" ] || exit 64
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
        if /usr/bin/open "$app"; then exit 0; fi
        if [ -n "$app" ] && [ -n "$backup" ] && [ -d "$backup" ]; then
            /bin/rm -rf "$app" && /bin/mv "$backup" "$app" && /usr/bin/open "$app"
        fi
        """

    /// Arguments for `/bin/sh` that run `relaunchScript`. Paths are passed as arguments, never
    /// spliced into the script, so no quoting is needed.
    public static func relaunchArguments(processID: Int32, appURL: URL, backupURL: URL?) -> [String] {
        ["-c", relaunchScript, "cybokron-relaunch", String(processID), appURL.path, backupURL?.path ?? ""]
    }

    // MARK: - Cleanup

    /// Deletes downloads, staged apps and empty mount points from earlier runs, and all but the
    /// newest `keepingBackups` backups.
    public func removeLeftovers(keepingBackups: Int = 1) {
        let fileManager = FileManager.default
        for folder in [directories.downloads, directories.staging] where fileManager.fileExists(atPath: folder.path) {
            try? fileManager.removeItem(at: folder)
        }
        let mounts = (try? fileManager.contentsOfDirectory(at: directories.mounts, includingPropertiesForKeys: nil)) ?? []
        mounts.forEach(Self.removeEmptyDirectory)
        Self.removeEmptyDirectory(directories.mounts)

        let found = (try? fileManager.contentsOfDirectory(
            at: directories.backups,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dated: [(url: URL, date: Date)] = found.map { ($0, Self.backupDate(of: $0)) }
        // Newest first.
        let backups = dated.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.url.lastPathComponent > rhs.url.lastPathComponent : lhs.date > rhs.date
        }.map(\.url)
        for backup in backups.dropFirst(max(keepingBackups, 0)) {
            try? fileManager.removeItem(at: backup)
        }
    }

    /// `"<name> 20261019-114500.app"`: when `replace` moved the app aside.
    static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// When a backup was made: the time `replace` put in its name. Moving an app keeps its folder's
    /// modification date — the date the old version was built or installed, not backed up — so
    /// that date only counts for a backup without a time in its name.
    static func backupDate(of backup: URL) -> Date {
        let name = backup.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #" \d{8}-\d{6}$"#, options: .regularExpression),
           let date = backupTimestampFormatter.date(from: String(name[range].dropFirst())) {
            return date
        }
        return (try? backup.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Removes `directory` only when it's empty, so a still-mounted disk image is never touched.
    private static func removeEmptyDirectory(_ directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path), entries.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// The last path component of a server-provided name, never empty or hidden.
    static func safeFileName(_ name: String) -> String {
        let component = URL(fileURLWithPath: name).lastPathComponent
        return component.isEmpty || component.hasPrefix(".") || component == "/" ? "update.dmg" : component
    }
}

/// Holds a download task for cancellation and reports its progress.
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        let cancelled = lock.withLock { () -> Bool in
            self.task = task
            observation = task.progress.observe(\.fractionCompleted, options: [.new]) { observed, _ in
                progress(observed.fractionCompleted)
            }
            return isCancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// An app's code signature as `codesign` describes it.
public struct CodeSignature: Equatable, Sendable {
    /// The designated requirement is anchored at Apple's certificates (`anchor apple generic` for a
    /// Developer ID): the app was signed with a certificate Apple issued. Ad hoc signatures name
    /// only the code's hashes (`cdhash H"…"`).
    public let isAppleAnchored: Bool
    /// The signing team, `nil` when there's none ("not set"), as for ad hoc signatures.
    public let teamIdentifier: String?

    public init(isAppleAnchored: Bool, teamIdentifier: String?) {
        self.isAppleAnchored = isAppleAnchored
        self.teamIdentifier = teamIdentifier
    }

    /// Reads the output of `codesign -d -r-` (the designated requirement) and of
    /// `codesign -dv --verbose=2` (the `TeamIdentifier=` line).
    public init(requirementOutput: String, detailsOutput: String) {
        let designated = requirementOutput.components(separatedBy: .newlines)
            .first { $0.hasPrefix("designated =>") }
        isAppleAnchored = designated?.contains("anchor apple") ?? false
        let team = detailsOutput.components(separatedBy: .newlines)
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)).trimmingCharacters(in: .whitespaces) }
        teamIdentifier = team.flatMap { $0.isEmpty || $0 == "not set" ? nil : $0 }
    }

    /// The team to hold later versions to: only a signature anchored at Apple vouches for one.
    public var signingTeam: String? {
        isAppleAnchored ? teamIdentifier : nil
    }
}
