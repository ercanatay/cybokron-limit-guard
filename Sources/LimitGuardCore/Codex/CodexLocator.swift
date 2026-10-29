import Foundation

/// Finds the `codex` executable the app should talk to.
public struct CodexLocator: Sendable {
    public static let chatGPTPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

    private let fileExists: @Sendable (String) -> Bool
    private let pathLookup: @Sendable () -> String?
    private let homeDirectory: String

    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathLookup: @escaping @Sendable () -> String? = CodexLocator.loginShellLookup,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.fileExists = fileExists
        self.pathLookup = pathLookup
        self.homeDirectory = homeDirectory
    }

    /// Order: user override, the ChatGPT app bundle, `codex` on the login-shell PATH, `~/.local/bin/codex`.
    public func resolve(override: String?) -> URL? {
        var candidates: [String] = []
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }
        candidates.append(Self.chatGPTPath)
        if let found = pathLookup(), !found.isEmpty { candidates.append(found) }
        candidates.append(homeDirectory + "/.local/bin/codex")
        for path in candidates where fileExists(path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return nil
    }

    /// `codex --version` trimmed, e.g. "codex-cli 0.165.0"; nil when it fails or takes longer than 5 s.
    public func version(of url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = url
            process.arguments = ["--version"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let once = Once(continuation)
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                once.resume(process.terminationStatus == 0 && !text.isEmpty ? text : nil)
            }
            do { try process.run() } catch { once.resume(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
                once.resume(nil)
            }
        }
    }

    /// `command -v codex` through a login shell so Homebrew/npm PATH entries are visible to a GUI app.
    @Sendable public static func loginShellLookup() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let line = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line?.hasPrefix("/") == true ? line : nil
    }
}

/// Resumes a continuation at most once (process exit and watchdog race).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func resume(_ value: String?) {
        let taken = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
