import Foundation
import Testing
@testable import LimitGuardCore

@Suite("CodexLocator")
struct CodexLocatorTests {
    private func locator(existing: Set<String>, path: String? = nil) -> CodexLocator {
        CodexLocator(fileExists: { existing.contains($0) }, pathLookup: { path }, homeDirectory: "/Users/test")
    }

    @Test func locatorPrefersOverride() {
        let all: Set = ["/custom/codex", CodexLocator.chatGPTPath, "/opt/bin/codex", "/Users/test/.local/bin/codex"]
        #expect(locator(existing: all, path: "/opt/bin/codex").resolve(override: "/custom/codex")?.path == "/custom/codex")
    }

    @Test func locatorFallsBackToChatGPTPath() {
        let url = locator(existing: [CodexLocator.chatGPTPath, "/opt/bin/codex"], path: "/opt/bin/codex")
            .resolve(override: "/missing/codex")
        #expect(url?.path == CodexLocator.chatGPTPath)
    }

    @Test func locatorUsesPathThenLocalBin() {
        #expect(locator(existing: ["/opt/bin/codex", "/Users/test/.local/bin/codex"], path: "/opt/bin/codex")
            .resolve(override: nil)?.path == "/opt/bin/codex")
        #expect(locator(existing: ["/Users/test/.local/bin/codex"]).resolve(override: nil)?.path
            == "/Users/test/.local/bin/codex")
        #expect(locator(existing: []).resolve(override: nil) == nil)
    }

    @Test func locatorResolvesSymlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real-codex")
        let link = dir.appendingPathComponent("link-codex")
        try "#!/bin/sh\necho 'codex-cli 9.9.9'\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let resolved = CodexLocator(fileExists: { FileManager.default.isExecutableFile(atPath: $0) }, pathLookup: { nil })
            .resolve(override: link.path)
        #expect(resolved?.lastPathComponent == "real-codex")
    }

    @Test func versionParsesStdout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lg-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-codex")
        try "#!/bin/sh\necho 'codex-cli 0.165.0'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        #expect(await CodexLocator().version(of: script) == "codex-cli 0.165.0")
        #expect(await CodexLocator().version(of: dir.appendingPathComponent("absent")) == nil)
    }
}
