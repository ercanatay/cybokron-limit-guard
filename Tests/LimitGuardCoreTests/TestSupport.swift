import Foundation

/// A fresh directory under the temporary directory (or under `base`), removed by `remove()`.
struct TemporaryDirectory {
    let url: URL

    init(base: URL = FileManager.default.temporaryDirectory) throws {
        url = base.appending(path: "CybokronLimitGuardTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Loads a JSON fixture from Tests/LimitGuardCoreTests/Fixtures.
func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)")
    return try Data(contentsOf: url)
}
