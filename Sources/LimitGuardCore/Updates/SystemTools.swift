import Foundation

/// The result of running a command-line tool.
public struct ToolResult: Equatable, Sendable {
    public let status: Int32
    /// Standard output and standard error, combined.
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    public var succeeded: Bool { status == 0 }
}

/// A tool that isn't there or can't be started.
public enum ToolRunError: Error, Equatable, Sendable {
    case toolMissing(String)
}

/// Runs the system tools the updater needs (codesign).
public protocol ToolRunning: Sendable {
    /// Runs `tool` with `arguments` and waits for it to exit. Throws `ToolRunError.toolMissing`
    /// when the tool can't be started.
    func run(_ tool: URL, arguments: [String]) async throws -> ToolResult
}

/// Paths of the system tools.
public enum SystemTools {
    public static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
}

/// `ToolRunning` with `Process`. Tools run off the main thread, without input, and their output is
/// collected for the log.
public struct SystemToolRunner: ToolRunning {
    public init() {}

    public func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw ToolRunError.toolMissing(tool.path)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ToolRunError.toolMissing(tool.path))
                    return
                }
                // Reading until end of file before waiting keeps a chatty tool from blocking on a
                // full pipe.
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ToolResult(
                    status: process.terminationStatus,
                    output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }
}
