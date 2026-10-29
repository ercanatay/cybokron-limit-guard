import Foundation
import Testing
@testable import LimitGuardCore

private func session(_ id: String, cwd: String, originator: String? = "codex-tui", seen: Set<String> = []) -> SessionState {
    SessionState(
        threadId: id, cwd: cwd, originator: originator, lastStop: .none, userActivityAfterStop: false,
        lastActivityAt: Date(timeIntervalSince1970: 0), lastTurnDurations: [], languageSample: "",
        seenClientMessageIds: seen)
}

private func tab(_ tty: String, cwd: String?, pid: Int32? = 100) -> TerminalTab {
    TerminalTab(ref: TabRef(windowId: 0, tabIndex: 0, tty: tty), title: "t", cwd: cwd, codexPid: pid, busy: false)
}

private func sentObjects(_ fake: FakeAppServer, method: String) -> [[String: Any]] {
    fake.sentLines.compactMap { line in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["method"] as? String == method else { return nil }
        return object
    }
}

@Suite("AppServerDelivery")
struct AppServerDeliveryTests {
    private let threadId = "019a0000-0000-7000-8000-000000000001"

    private func delivery(_ fake: FakeAppServer) -> AppServerDelivery {
        AppServerDelivery(client: AppServerClient(transportFactory: { fake }, clientName: "test", clientVersion: "0"))
    }

    @Test func turnStartHasNoOverrides() async throws {
        let fake = FakeAppServer()
        fake.script("thread/loaded/list", result: #"{"data":["\#(threadId)"],"nextCursor":null}"#)
        fake.script("turn/start", result: #"{"turn":{"id":"t1","status":"inProgress"}}"#)
        let id = UUID()
        let request = ContinueRequest(threadId: threadId, text: "devam et", clientMessageId: id, tab: nil)
        #expect(await delivery(fake).deliver(request) == .sent)

        let starts = sentObjects(fake, method: "turn/start")
        #expect(starts.count == 1)
        let params = try #require(starts.first?["params"] as? [String: Any])
        #expect(Set(params.keys) == ["threadId", "input", "clientUserMessageId"])
        #expect(params["threadId"] as? String == threadId)
        #expect(params["clientUserMessageId"] as? String == id.uuidString.lowercased())
        let input = try #require(params["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(Set(input[0].keys) == ["type", "text"])
        #expect(input[0]["type"] as? String == "text")
        #expect(input[0]["text"] as? String == "devam et")
    }

    @Test func notLoadedIsRefused() async {
        let fake = FakeAppServer()
        fake.script("thread/loaded/list", result: #"{"data":["other"],"nextCursor":null}"#)
        let request = ContinueRequest(threadId: threadId, text: "continue", clientMessageId: UUID(), tab: nil)
        #expect(await delivery(fake).deliver(request) == .refused("thread not loaded"))
        #expect(sentObjects(fake, method: "turn/start").isEmpty)
    }

    @Test func followsTheLoadedListCursor() async throws {
        let fake = FakeAppServer()
        fake.scriptQueue("thread/loaded/list", [
            .result(#"{"data":["a","b"],"nextCursor":"page2"}"#),
            .result(#"{"data":["\#(threadId)"],"nextCursor":null}"#),
        ])
        fake.script("turn/start", result: #"{"turn":{"id":"t1"}}"#)
        let request = ContinueRequest(threadId: threadId, text: "continue", clientMessageId: UUID(), tab: nil)
        #expect(await delivery(fake).deliver(request) == .sent)
        let lists = sentObjects(fake, method: "thread/loaded/list")
        #expect(lists.count == 2)
        #expect((lists[0]["params"] as? [String: Any])?.isEmpty == true)
        #expect((lists[1]["params"] as? [String: Any])?["cursor"] as? String == "page2")
    }

    @Test func aRepeatedCursorStopsPaging() async throws {
        let fake = FakeAppServer()
        fake.script("thread/loaded/list", result: #"{"data":["a"],"nextCursor":"same"}"#)
        let ids = try await delivery(fake).loadedThreadIds()
        #expect(ids == ["a"])
        #expect(sentObjects(fake, method: "thread/loaded/list").count == 2)
    }

    @Test func turnStartErrorsFail() async {
        let fake = FakeAppServer()
        fake.script("thread/loaded/list", result: #"{"data":["\#(threadId)"]}"#)
        fake.scriptError("turn/start", code: -32600, message: "busy")
        let request = ContinueRequest(threadId: threadId, text: "continue", clientMessageId: UUID(), tab: nil)
        #expect(await delivery(fake).deliver(request) == .failed("turn/start: rpc error -32600: busy"))
    }

    @Test func listErrorsFailWithoutStartingATurn() async {
        let fake = FakeAppServer()
        fake.scriptError("thread/loaded/list", code: -32601, message: "unknown method")
        let request = ContinueRequest(threadId: threadId, text: "continue", clientMessageId: UUID(), tab: nil)
        #expect(await delivery(fake).deliver(request) == .failed("thread/loaded/list: rpc error -32601: unknown method"))
        #expect(sentObjects(fake, method: "turn/start").isEmpty)
    }

    @Test func emptyTextIsRefused() async {
        let fake = FakeAppServer()
        let request = ContinueRequest(threadId: threadId, text: "  \n", clientMessageId: UUID(), tab: nil)
        #expect(await delivery(fake).deliver(request) == .refused("empty continue text"))
        #expect(fake.sentLines.isEmpty)
    }

    @Test func readsThreadCwdAndStatus() async throws {
        let fake = FakeAppServer()
        fake.script("thread/read", result: #"{"thread":{"id":"\#(threadId)","cwd":"/Users/me/project","status":{"type":"systemError"},"ephemeral":false,"turns":[]}}"#)
        let info = try await delivery(fake).readThread(threadId)
        #expect(info == ThreadInfo(threadId: threadId, cwd: "/Users/me/project", statusType: "systemError", ephemeral: false))
        let reads = sentObjects(fake, method: "thread/read")
        let params = try #require(reads.first?["params"] as? [String: Any])
        #expect(params["threadId"] as? String == threadId)
        #expect(params["includeTurns"] as? Bool == false)
        #expect(Set(params.keys) == ["threadId", "includeTurns"])
    }

    @Test func loadedThreadCwdsSkipEphemeralAndUnreadableThreads() async throws {
        let fake = FakeAppServer()
        fake.script("thread/loaded/list", result: #"{"data":["a","b","c"]}"#)
        fake.scriptQueue("thread/read", [
            .result(#"{"thread":{"id":"a","cwd":"/p/a","status":{"type":"idle"},"ephemeral":false}}"#),
            .result(#"{"thread":{"id":"b","cwd":"/p/b","status":{"type":"idle"},"ephemeral":true}}"#),
            .error(code: -32600, message: "gone"),
        ])
        #expect(try await delivery(fake).loadedThreadCwds() == ["a": "/p/a"])
    }

    @Test func undecodableThreadReadThrows() async {
        let fake = FakeAppServer()
        fake.script("thread/read", result: #"{"nothing":true}"#)
        await #expect(throws: ProtocolDecodingError.self) { try await delivery(fake).readThread("x") }
    }
}

@Suite("DeliveryConfirmer")
struct DeliveryConfirmerTests {
    @Test func confirmedByClientMessageId() {
        let id = UUID()
        let request = ContinueRequest(threadId: "t", text: "continue", clientMessageId: id, tab: nil)
        #expect(DeliveryConfirmer.isConfirmed(request: request, session: session("t", cwd: "/p", seen: [id.uuidString.lowercased()])))
        #expect(DeliveryConfirmer.isConfirmed(request: request, session: session("t", cwd: "/p", seen: [id.uuidString])))
        #expect(!DeliveryConfirmer.isConfirmed(request: request, session: session("t", cwd: "/p", seen: [UUID().uuidString.lowercased()])))
        // Another thread that happens to carry the id does not confirm this request.
        #expect(!DeliveryConfirmer.isConfirmed(request: request, session: session("u", cwd: "/p", seen: [id.uuidString.lowercased()])))
    }
}

@Suite("TabMatcher")
struct TabMatcherTests {
    @Test func oneTabOneThreadPairs() {
        let threads = [session("t1", cwd: "/p/a")]
        #expect(TabMatcher.match(tabs: [tab("/dev/ttys003", cwd: nil)], threads: threads, loadedThreadCwds: ["t1": "/p/a"])
            == [TabRef(windowId: 0, tabIndex: 0, tty: "/dev/ttys003"): "t1"])
        #expect(TabMatcher.match(single: tab("/dev/ttys003", cwd: "/p/a/"), threads: threads, loadedThreadCwds: ["t1": "/p/a"]) == "t1")
    }

    @Test func oneTabOneThreadWithDifferentCwdsDoesNotPair() {
        let threads = [session("t1", cwd: "/p/a")]
        #expect(TabMatcher.match(tabs: [tab("/dev/ttys003", cwd: "/p/b")], threads: threads, loadedThreadCwds: ["t1": "/p/a"]).isEmpty)
    }

    @Test func singleTabWithSecondLoadedThreadInSameCwdIsAmbiguous() {
        let threads = [session("t1", cwd: "/p/a")]
        let loaded = ["t1": "/p/a", "t2": "/p/a"]
        #expect(TabMatcher.match(tabs: [tab("/dev/ttys003", cwd: "/p/a")], threads: threads, loadedThreadCwds: loaded).isEmpty)
    }

    @Test func nilCwdTabWithTwoLoadedThreadsIsAmbiguous() {
        let threads = [session("t1", cwd: "/p/a")]
        let loaded = ["t1": "/p/a", "t2": "/p/b"]
        #expect(TabMatcher.match(tabs: [tab("/dev/ttys003", cwd: nil)], threads: threads, loadedThreadCwds: loaded).isEmpty)
    }

    @Test func cwdSeparatesTwoTabs() {
        let tabs = [tab("/dev/ttys003", cwd: "/p/a"), tab("/dev/ttys004", cwd: "/p/b", pid: 101)]
        let threads = [session("t1", cwd: "/p/a"), session("t2", cwd: "/p/b")]
        let map = TabMatcher.match(tabs: tabs, threads: threads, loadedThreadCwds: ["t1": "/p/a", "t2": "/p/b"])
        #expect(map == [tabs[0].ref: "t1", tabs[1].ref: "t2"])
    }

    @Test func ambiguousMappingReturnsNil() {
        let tabs = [tab("/dev/ttys003", cwd: "/p/a"), tab("/dev/ttys004", cwd: "/p/a", pid: 101)]
        let threads = [session("t1", cwd: "/p/a"), session("t2", cwd: "/p/a")]
        #expect(TabMatcher.match(tabs: tabs, threads: threads, loadedThreadCwds: ["t1": "/p/a", "t2": "/p/a"]).isEmpty)
        #expect(TabMatcher.match(single: tabs[0], threads: threads, loadedThreadCwds: ["t1": "/p/a", "t2": "/p/a"]) == nil)
    }

    @Test func aSecondLoadedThreadInTheSameCwdMakesItAmbiguous() {
        // t2 is loaded (some other TUI) but not a candidate; the /p/a tab could belong to either.
        let tabs = [tab("/dev/ttys003", cwd: "/p/a"), tab("/dev/ttys004", cwd: "/p/b", pid: 101)]
        let threads = [session("t1", cwd: "/p/a")]
        let map = TabMatcher.match(tabs: tabs, threads: threads, loadedThreadCwds: ["t1": "/p/a", "t2": "/p/a"])
        #expect(map.isEmpty)
    }

    @Test func onlyLoadedTuiThreadsAndCodexTabsAreCandidates() {
        let tabs = [tab("/dev/ttys003", cwd: "/p/a"), tab("/dev/ttys004", cwd: "/p/b", pid: nil)]
        let threads = [session("t1", cwd: "/p/a"), session("t2", cwd: "/p/b"), session("t3", cwd: "/p/c", originator: "codex_exec")]
        // t2 is not loaded; the ttys004 tab has no Codex process; t3 is not a TUI thread.
        let map = TabMatcher.match(tabs: tabs, threads: threads, loadedThreadCwds: ["t1": "/p/a", "t3": "/p/c"])
        #expect(map == [tabs[0].ref: "t1"])
    }

    @Test func usesTheLiveCwdFromThreadRead() {
        let tabs = [tab("/dev/ttys003", cwd: "/p/new"), tab("/dev/ttys004", cwd: "/p/b", pid: 101)]
        let threads = [session("t1", cwd: "/p/old"), session("t2", cwd: "/p/b")]
        let map = TabMatcher.match(tabs: tabs, threads: threads, loadedThreadCwds: ["t1": "/p/new", "t2": "/p/b"])
        #expect(map == [tabs[0].ref: "t1", tabs[1].ref: "t2"])
    }
}

@Suite("CodexProcessLister")
struct CodexProcessListerTests {
    // Trimmed real `ps -axo pid=,tty=,comm=` output (home folder anonymised).
    static let psOutput = """
     1550 ??       /Users/me/.codex/packages/app-server-daemon/releases/0.165.0-aarch64-apple-darwin/bin/codex-code-mode-host
    12636 ??       /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/156.0.8078.48/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)
    13132 ??       /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
     8963 ttys003  /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/../CodexCLI.app/Contents/MacOS/codex
     9001 ttys003  /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/../CodexCLI.app/Contents/MacOS/codex
    98826 ttys004  /Users/me/.codex/tools/gws-mcp-0.7.0/node_modules/@googleworkspace/cli/node_modules/.bin_real/gws
     8506 ttys003  -zsh
    94848 ttys009  /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/../CodexCLI.app/Contents/MacOS/codex

    """

    @Test func keepsOneTtyCodexProcessPerTty() {
        let processes = CodexProcessLister.parseProcessList(Self.psOutput)
        #expect(processes.map(\.pid) == [8963, 94848])
        #expect(processes.map(\.tty) == ["/dev/ttys003", "/dev/ttys009"])
        #expect(processes[0].executable == "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/../CodexCLI.app/Contents/MacOS/codex")
    }

    @Test func parsesTheLsofCwd() {
        #expect(CodexProcessLister.parseCwd("p8963\nfcwd\nn/Users/me/project with space\n") == "/Users/me/project with space")
        #expect(CodexProcessLister.parseCwd("p8963\nftxt\nn/bin/codex\n") == nil)
        #expect(CodexProcessLister.parseCwd("") == nil)
    }

    private struct ScriptedTools: ToolRunning {
        let outputs: [String: String]
        func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
            let key = ([tool.path] + arguments).joined(separator: " ")
            guard let output = outputs[key] else { return ToolResult(status: 1, output: "") }
            return ToolResult(status: 0, output: output)
        }
    }

    @Test func buildsTabsFromProcessesAndTheirCwd() async {
        let tools = ScriptedTools(outputs: [
            "/bin/ps -axo pid=,tty=,comm=": Self.psOutput,
            "/usr/sbin/lsof -a -p 8963 -d cwd -Fn": "p8963\nfcwd\nn/Users/me/limit-guard",
        ])
        let tabs = await CodexProcessLister(tools: tools).tabs()
        #expect(tabs == [
            TerminalTab(ref: TabRef(windowId: 0, tabIndex: 0, tty: "/dev/ttys003"), title: "limit-guard",
                        cwd: "/Users/me/limit-guard", codexPid: 8963, busy: false),
            TerminalTab(ref: TabRef(windowId: 0, tabIndex: 0, tty: "/dev/ttys009"), title: "ttys009",
                        cwd: nil, codexPid: 94848, busy: false),
        ])
    }

    @Test func aFailingPsGivesNoTabs() async {
        #expect(await CodexProcessLister(tools: ScriptedTools(outputs: [:])).tabs().isEmpty)
    }
}
