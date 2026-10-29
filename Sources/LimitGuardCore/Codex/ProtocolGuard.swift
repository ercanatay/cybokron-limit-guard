import Foundation

/// Whether the app-server reply had every field Limit Guard relies on to act (continue, spend a credit).
public enum ProtocolHealth: Equatable, Sendable {
    case full
    /// A required field was missing or malformed: keep showing data but never act on it.
    case readOnly(reason: String)
}

public struct ProtocolDecodingError: Error, Equatable, Sendable {
    public let message: String
}

/// Tolerant accessors over `JSONSerialization` output; unknown keys are ignored, `bigint` values may be numbers.
enum JSONField {
    static func object(from data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data), let dict = root as? [String: Any] else {
            throw ProtocolDecodingError(message: "expected a JSON object")
        }
        return dict
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9.0e18 else { return nil }
        return number.int64Value
    }

    static func int(_ value: Any?) -> Int? {
        int64(value).flatMap { Int(exactly: $0) }
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// Unix seconds.
    static func date(_ value: Any?) -> Date? {
        double(value).map { Date(timeIntervalSince1970: $0) }
    }
}
