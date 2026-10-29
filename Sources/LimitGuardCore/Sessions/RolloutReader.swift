import Foundation

/// Reads the end of a rollout file. Rollouts grow for days (resumed sessions reach tens of MB), so
/// only the last `maxBytes` are decoded; the thread's `session_meta` is read from the first line.
public struct RolloutReader {
    /// The first line carries the full base instructions; stop looking for its end after this much.
    static let maxFirstLineBytes = 8 * 1_024 * 1_024

    public init() {}

    /// Events in file order, `sessionMeta` first when the first line is one. Lines that are not JSON
    /// (a partial line at the cut or one still being written) are skipped. Throws on I/O errors.
    public func tailEvents(of url: URL, maxBytes: Int = 512_000) throws -> [RolloutEvent] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0

        var events: [RolloutEvent] = []
        if start > 0, let firstLine = try readFirstLine(handle),
           case let .event(meta)? = RolloutEvent.decode(line: firstLine, isFirstLine: true), case .sessionMeta = meta {
            events.append(meta)
        }

        try handle.seek(toOffset: start)
        var tail = try handle.readToEnd() ?? Data()
        if start > 0 {
            // The window starts mid-line unless the byte before it ends a line.
            try handle.seek(toOffset: start - 1)
            let previous = try handle.read(upToCount: 1)
            if previous != Data([0x0A]) {
                guard let newline = tail.firstIndex(of: 0x0A) else { return events }
                tail = tail[tail.index(after: newline)...]
            }
        }

        var isFirstLine = start == 0
        for line in tail.split(separator: 0x0A, omittingEmptySubsequences: false) {
            defer { isFirstLine = false }
            guard !line.isEmpty, let decoded = RolloutEvent.decode(line: Data(line), isFirstLine: isFirstLine) else {
                continue
            }
            switch decoded {
            case let .event(event):
                events.append(event)
            case let .userItem(text, at, clientId):
                appendUserItem(text: text, at: at, clientId: clientId, to: &events)
            }
        }
        return events
    }

    /// A `UserMessage` item repeats the user message just before it: fold its client id into that
    /// message. Without such a message (cut off by the tail window) the item stands for it.
    private func appendUserItem(text: String, at: Date, clientId: String?, to events: inout [RolloutEvent]) {
        if let index = events.lastIndex(where: { if case .userMessage = $0 { return true } else { return false } }),
           case let .userMessage(previousText, previousAt, nil) = events[index], previousText == text {
            events[index] = .userMessage(text: previousText, at: previousAt, clientMessageId: clientId)
            return
        }
        events.append(.userMessage(text: text, at: at, clientMessageId: clientId))
    }

    /// The last `count` real user messages (see `LanguageSample`), oldest first, read backwards from
    /// the end of the file. Long turns push the owner's messages megabytes before the end (up to
    /// ~15 MB for the third-last one in real rollouts), far outside `tailEvents`' window; this stops
    /// after `maxBytes` and decodes only lines that mention a user role.
    public func recentUserMessages(of url: URL, count: Int = 3, maxBytes: Int = 32 * 1_024 * 1_024) throws -> [String] {
        try recentUserMessages(of: url, count: count, maxBytes: maxBytes, chunkSize: 1_024 * 1_024)
    }

    func recentUserMessages(of url: URL, count: Int, maxBytes: Int, chunkSize: Int) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let floor = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        let marker = Data(#""role":"user""#.utf8)

        var messages: [String] = []
        var position = size
        var carry = Data() // the start of a line whose beginning lies before `position`
        while position > floor, messages.count < count {
            let start = max(floor, position >= UInt64(chunkSize) ? position - UInt64(chunkSize) : 0)
            try handle.seek(toOffset: start)
            var buffer = try handle.read(upToCount: Int(position - start)) ?? Data()
            buffer.append(carry)
            position = start
            var lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
            // Unless at the file start, the first piece may be cut; keep it for the next chunk.
            carry = position > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() where messages.count < count && line.range(of: marker) != nil {
                guard case let .event(.userMessage(text, _, _))? = RolloutEvent.decode(line: Data(line), isFirstLine: false)
                else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if LanguageSample.isReal(trimmed) { messages.insert(trimmed, at: 0) }
            }
        }
        return messages
    }

    private func readFirstLine(_ handle: FileHandle) throws -> Data? {
        try handle.seek(toOffset: 0)
        var line = Data()
        while line.count < Self.maxFirstLineBytes {
            guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else { return nil }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex..<newline])
                return line
            }
            line.append(chunk)
        }
        return nil
    }
}
