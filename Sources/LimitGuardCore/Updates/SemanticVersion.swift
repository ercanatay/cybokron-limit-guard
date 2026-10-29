import Foundation

/// A version number such as `0.5.1`, `v1.0.0` or `1.2.0-beta.2`, ordered by the Semantic Versioning
/// 2.0 precedence rules: numbers compare numerically, a prerelease comes before its release, and build
/// metadata (`+…`) is ignored.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated prerelease identifiers (`["beta", "2"]`); empty for a release.
    public let prerelease: [String]
    /// Build metadata after `+`; it never affects the order.
    public let build: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = [], build: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// Parses a version or a release tag. A leading `v` is allowed, and missing minor or patch
    /// numbers count as 0 (`v1.2` is `1.2.0`). Returns `nil` for anything else.
    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" {
            text = text.dropFirst()
        }
        var build: String?
        if let plus = text.firstIndex(of: "+") {
            build = String(text[text.index(after: plus)...])
            text = text[..<plus]
            guard let build, Self.areValidIdentifiers(build) else { return nil }
        }
        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let identifiers = String(text[text.index(after: dash)...])
            guard Self.areValidIdentifiers(identifiers) else { return nil }
            prerelease = identifiers.split(separator: ".").map(String.init)
            text = text[..<dash]
        }
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count) else { return nil }
        var values: [Int] = []
        for number in numbers {
            guard !number.isEmpty, number.allSatisfy(\.isASCIIDigit), let value = Int(number) else { return nil }
            values.append(value)
        }
        while values.count < 3 {
            values.append(0)
        }
        self.init(major: values[0], minor: values[1], patch: values[2], prerelease: prerelease, build: build)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// `1.2.3`, `1.2.3-beta.2` or `1.2.3+build`; without a `v`.
    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            text += "-" + prerelease.joined(separator: ".")
        }
        if let build {
            text += "+" + build
        }
        return text
    }

    // MARK: - Order

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let left = [lhs.major, lhs.minor, lhs.patch]
        let right = [rhs.major, rhs.minor, rhs.patch]
        if left != right {
            return left.lexicographicallyPrecedes(right)
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            return precedes(lhs.prerelease, rhs.prerelease)
        }
    }

    /// Equal precedence: build metadata is ignored, consistent with `<`.
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    /// Prerelease identifiers compare one by one: numeric ones numerically and before alphanumeric
    /// ones, alphanumeric ones in ASCII order; a shorter list that matches so far comes first.
    private static func precedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return left < right
            }
        }
        return lhs.count < rhs.count
    }

    private static func areValidIdentifiers(_ text: String) -> Bool {
        let identifiers = text.split(separator: ".", omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
