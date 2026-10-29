import Foundation

/// A Codex CLI process attached to a terminal.
public struct CodexProcess: Equatable, Sendable {
    public var pid: Int32
    /// `/dev/ttysNNN`, the form Terminal's `tty of tab` uses.
    public var tty: String
    public var executable: String

    public init(pid: Int32, tty: String, executable: String) {
        self.pid = pid
        self.tty = tty
        self.executable = executable
    }
}

/// Finds Codex TUIs from `ps` and their working folders from `lsof` (spike S2).
public struct CodexProcessLister: Sendable {
    static let ps = URL(fileURLWithPath: "/bin/ps")
    static let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")

    private let tools: ToolRunning

    public init(tools: ToolRunning = SystemToolRunner()) {
        self.tools = tools
    }

    /// One tab per tty with a Codex process; `cwd` is nil when `lsof` cannot tell.
    public func tabs() async -> [TerminalTab] {
        var tabs: [TerminalTab] = []
        for process in await processes() {
            let cwd = await cwd(of: process.pid)
            let title = cwd.map { ($0 as NSString).lastPathComponent }
                ?? (process.tty as NSString).lastPathComponent
            tabs.append(TerminalTab(
                ref: TabRef(windowId: 0, tabIndex: 0, tty: process.tty),
                title: title, cwd: cwd, codexPid: process.pid, busy: false))
        }
        return tabs
    }

    public func processes() async -> [CodexProcess] {
        guard let result = try? await tools.run(Self.ps, arguments: ["-axo", "pid=,tty=,comm="]), result.succeeded else {
            return []
        }
        return Self.parseProcessList(result.output)
    }

    public func cwd(of pid: Int32) async -> String? {
        guard let result = try? await tools.run(Self.lsof, arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]),
              result.succeeded else { return nil }
        return Self.parseCwd(result.output)
    }

    /// `ps -axo pid=,tty=,comm=` output → processes named `codex` with a real tty (not `??`), the lowest
    /// pid per tty (a TUI's own `codex` children share its tty), sorted by tty. The ChatGPT app's
    /// tty-less Codex processes are skipped.
    public static func parseProcessList(_ text: String) -> [CodexProcess] {
        var byTty: [String: CodexProcess] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            // The command is the rest of the line and may contain spaces.
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]) else { continue }
            let tty = String(fields[1])
            let command = fields[2].trimmingCharacters(in: .whitespaces)
            guard tty != "??", tty != "-", (command as NSString).lastPathComponent == "codex" else { continue }
            let device = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            if let existing = byTty[device], existing.pid < pid { continue }
            byTty[device] = CodexProcess(pid: pid, tty: device, executable: command)
        }
        return byTty.values.sorted { $0.tty < $1.tty }
    }

    /// `lsof -a -p <pid> -d cwd -Fn` output → the `n` line of the `fcwd` file.
    public static func parseCwd(_ text: String) -> String? {
        var inCwd = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("f") {
                inCwd = line == "fcwd"
            } else if inCwd, line.hasPrefix("n") {
                let path = String(line.dropFirst())
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }
}
