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

private final class FixtureBundleToken {}

/// A fixture's file URL: SwiftPM keeps the Fixtures folder, the Xcode test bundle copies the files flat.
func fixtureURL(_ name: String) -> URL {
    #if SWIFT_PACKAGE
    return Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)")
    #else
    let bundle = Bundle(for: FixtureBundleToken.self)
    return bundle.url(forResource: name, withExtension: nil)
        ?? bundle.resourceURL!.appending(path: "Fixtures/\(name)")
    #endif
}

/// Loads a fixture's contents.
func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}
