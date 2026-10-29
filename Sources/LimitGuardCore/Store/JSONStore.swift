import Foundation

public enum StoreError: Error, Equatable {
    /// The file was written by a newer app version; it must be treated as read-only.
    case newerSchema(found: Int)
    /// The file's top level is not a JSON object.
    case notAnObject
}

/// A single versioned JSON file. The file is a JSON object with a `schemaVersion` key next to the
/// value's own keys. Missing keys decode to defaults (see the value types' `init(from:)`).
public struct JSONStore<Value: Codable> {
    public let url: URL
    public let schemaVersion: Int

    public init(url: URL, schemaVersion: Int) {
        self.url = url
        self.schemaVersion = schemaVersion
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Returns nil when the file does not exist. Throws `StoreError.newerSchema` for a newer file.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.notAnObject
        }
        if let found = (object["schemaVersion"] as? NSNumber)?.intValue, found > schemaVersion {
            throw StoreError.newerSchema(found: found)
        }
        return try Self.decoder.decode(Value.self, from: data)
    }

    /// Atomic write; creates the parent directory.
    public func save(_ value: Value) throws {
        let encoded = try Self.encoder.encode(value)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw StoreError.notAnObject
        }
        object["schemaVersion"] = schemaVersion
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Copies every `*.json` in `dir` to `<name>.pre-downgrade-<timestamp>.json` (used before a
/// downgrade so a newer app version can still find its files).
public func makePreDowngradeCopies(in dir: URL, timestamp: String) throws {
    let fm = FileManager.default
    let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    for file in files where file.pathExtension == "json" && !file.lastPathComponent.contains(".pre-downgrade-") {
        let name = file.deletingPathExtension().lastPathComponent
        let copy = dir.appendingPathComponent("\(name).pre-downgrade-\(timestamp).json")
        if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
        try fm.copyItem(at: file, to: copy)
    }
}
