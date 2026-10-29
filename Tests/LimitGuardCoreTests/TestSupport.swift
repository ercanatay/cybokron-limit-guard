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

/// Loads a JSON fixture: SwiftPM keeps the Fixtures folder, the Xcode test bundle copies the files flat.
func fixture(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let url = Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)")
    #else
    let bundle = Bundle(for: FixtureBundleToken.self)
    let url = bundle.url(forResource: name, withExtension: nil)
        ?? bundle.resourceURL!.appending(path: "Fixtures/\(name)")
    #endif
    return try Data(contentsOf: url)
}
