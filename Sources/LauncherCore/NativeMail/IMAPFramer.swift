import Foundation

/// Cuts the server's byte stream into whole replies. A line that ends in `{n}` announces n bytes
/// of literal data, which can hold line breaks, so the reply goes on after them.
public struct IMAPFramer {
    private var buffer: [UInt8] = []
    /// Where the current reply starts in `buffer`. Consumed bytes are dropped in batches.
    private var start = 0
    /// Where the search for the next line end resumes, past any literal already counted.
    private var scan = 0
    /// Largest reply accepted: a message body arrives as one literal, so this bounds one message.
    public let maxReply: Int

    public init(maxReply: Int = 64 * 1024 * 1024) { self.maxReply = maxReply }

    public mutating func append(_ data: Data) {
        if start > 0, start >= buffer.count / 2 {
            buffer.removeSubrange(0..<start)
            scan -= start
            start = 0
        }
        buffer.append(contentsOf: data)
    }

    /// The next complete reply, or nil until more bytes arrive.
    public mutating func next() throws -> [UInt8]? {
        while true {
            guard let lf = firstLineFeed(from: scan) else {
                if buffer.count - start > maxReply { throw IMAPParseError(description: "The server sent a reply larger than \(maxReply / 1_048_576) MB.") }
                return nil
            }
            if let count = literalSize(endingAt: lf) {
                guard count <= maxReply else { throw IMAPParseError(description: "The server announced a literal of \(count) bytes.") }
                let end = lf + 1 + count
                guard end <= buffer.count else { return nil }
                scan = end
                continue
            }
            let reply = Array(buffer[start...lf])
            start = lf + 1
            scan = start
            return reply
        }
    }

    private func firstLineFeed(from index: Int) -> Int? {
        var cursor = index
        while cursor < buffer.count {
            if buffer[cursor] == Byte.lf { return cursor }
            cursor += 1
        }
        return nil
    }

    /// n for a line ending in `{n}` (or `{n+}` or `~{n}`) just before its CRLF.
    private func literalSize(endingAt lf: Int) -> Int? {
        var end = lf - 1
        if end >= start, buffer[end] == Byte.cr { end -= 1 }
        guard end >= start, buffer[end] == Byte.closeBrace else { return nil }
        var cursor = end - 1
        if cursor >= start, buffer[cursor] == Byte.plus { cursor -= 1 }
        let digitsEnd = cursor
        while cursor >= start, buffer[cursor] >= Byte.zero, buffer[cursor] <= Byte.nine { cursor -= 1 }
        guard cursor >= start, buffer[cursor] == Byte.openBrace, cursor < digitsEnd, digitsEnd - cursor <= 12 else { return nil }
        return Int(String(decoding: buffer[(cursor + 1)...digitsEnd], as: UTF8.self))
    }
}
