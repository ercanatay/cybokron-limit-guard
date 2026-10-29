import Foundation
import Testing
@testable import LimitGuardCore

@Suite("DataDirectory")
struct DataDirectoryTests {
    private let base = URL(fileURLWithPath: "/Users/test/Library/Application Support")
    private let override = URL(fileURLWithPath: "/tmp/lg-data", isDirectory: true)

    @Test func defaultIsTheApplicationSupportFolder() {
        let url = DataDirectory.resolve(environment: [:], honoursOverride: true, base: base)
        #expect(url.path == "/Users/test/Library/Application Support/Cybokron Limit Guard")
    }

    @Test func overrideCountsOnlyWhenHonoured() {
        let env = [DataDirectory.overrideVariable: override.path]
        #expect(DataDirectory.resolve(environment: env, honoursOverride: true, base: base).path == override.path)
        #expect(DataDirectory.resolve(environment: env, honoursOverride: false, base: base).path
            == "/Users/test/Library/Application Support/Cybokron Limit Guard")
        #expect(DataDirectory.resolve(environment: [DataDirectory.overrideVariable: ""], honoursOverride: true, base: base).path
            == "/Users/test/Library/Application Support/Cybokron Limit Guard")
    }

    @Test func everyUpdaterChangelogAndDowngradePathIsUnderTheDirectory() {
        let dir = DataDirectory.resolve(
            environment: [DataDirectory.overrideVariable: override.path], honoursOverride: true, base: base)
        let paths = [
            JSONFileUpdateStatePersistence.defaultFileURL(in: dir),
            JSONFileChangelogCachePersistence.defaultFileURL(in: dir),
            UpdateDirectories.defaultRoot(in: dir),
            UpdateDirectories(root: UpdateDirectories.defaultRoot(in: dir)).root,
        ]
        for path in paths { #expect(path.path.hasPrefix(dir.path + "/"), "\(path.path)") }
        #expect(dir.path == override.path)
    }

    @Test func theDefaultsAreBuiltFromTheOneDirectory() {
        let dir = DataDirectory.url
        #expect(JSONFileUpdateStatePersistence.defaultFileURL == JSONFileUpdateStatePersistence.defaultFileURL(in: dir))
        #expect(JSONFileChangelogCachePersistence.defaultFileURL == JSONFileChangelogCachePersistence.defaultFileURL(in: dir))
        #expect(UpdateDirectories.defaultRoot == UpdateDirectories.defaultRoot(in: dir))
        #expect(DowngradeProtection.dataDirectory == dir)
    }

    /// No other source may build the folder itself, or an override would miss it.
    @Test func noSourceOutsideDataDirectoryNamesTheRealFolder() throws {
        let sources = LocalizationTests.root.appending(path: "Sources", directoryHint: .isDirectory)
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" && file.lastPathComponent != "DataDirectory.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains("applicationSupportDirectory") || $0.contains("\"Application Support\"") }) {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
