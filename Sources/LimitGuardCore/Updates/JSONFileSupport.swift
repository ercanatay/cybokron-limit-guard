import Foundation

/// Where the updater keeps its small files, and how it writes them.
enum JSONFileSupport {
    /// The data folder (`DataDirectory.url`). Nothing in it leaves this Mac.
    static var directoryURL: URL { DataDirectory.url }

    /// Encodes `value` as pretty-printed JSON and writes it atomically, creating the folder if needed.
    static func write<T: Encodable>(_ value: T, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}

extension KeyedDecodingContainer {
    /// Decodes an optional value, treating a missing *or unreadable* one as absent.
    func decodeLeniently<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}
