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
        await listTabs() ?? []
    }

    /// `tabs()`, but nil when `ps` failed, so a caller can tell "no Codex tabs" from "couldn't list".
    /// A process whose start time can't be read (it just exited) is left out.
    public func listTabs() async -> [TerminalTab]? {
        guard let processes = await listProcesses() else { return nil }
        let starts = processes.isEmpty ? [:] : await startTimes(of: processes.map(\.pid))
        guard let starts else { return nil }
        var tabs: [TerminalTab] = []
        for process in processes {
            guard let startTime = starts[process.pid] else { continue }
            let cwd = await cwd(of: process.pid)
            let title = cwd.map { ($0 as NSString).lastPathComponent }
                ?? (process.tty as NSString).lastPathComponent
            tabs.append(TerminalTab(
                ref: TabRef(windowId: 0, tabIndex: 0, tty: process.tty, pid: process.pid, startTime: startTime),
                title: title, cwd: cwd, codexPid: process.pid, busy: false))
        }
        return tabs
    }

    public func processes() async -> [CodexProcess] {
        await listProcesses() ?? []
    }

    /// Nil when `ps` could not run or failed.
    public func listProcesses() async -> [CodexProcess]? {
        guard let result = try? await tools.run(Self.ps, arguments: ["-axo", "pid=,tty=,comm="]), result.succeeded else {
            return nil
        }
        return Self.parseProcessList(result.output)
    }

    /// pid → start time (`ps -o lstart=`); nil when `ps` failed.
    public func startTimes(of pids: [Int32]) async -> [Int32: String]? {
        let list = pids.map(String.init).joined(separator: ",")
        guard let result = try? await tools.run(Self.ps, arguments: ["-o", "pid=,lstart=", "-p", list]) else { return nil }
        let starts = Self.parseStartTimes(result.output)
        // `ps -p` exits 1 when one of the processes is gone; the lines of the others are still valid.
        // A failure without any line counts as a failed listing, so no guard is pruned on it.
        return result.succeeded || !starts.isEmpty ? starts : nil
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

    /// `ps -o pid=,lstart=` output → pid → the rest of the line, trimmed. The text depends on the
    /// locale, so it is only ever compared with itself.
    public static func parseStartTimes(_ text: String) -> [Int32: String] {
        var starts: [Int32: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]) else { continue }
            let start = fields[1].trimmingCharacters(in: .whitespaces)
            if !start.isEmpty { starts[pid] = start }
        }
        return starts
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
