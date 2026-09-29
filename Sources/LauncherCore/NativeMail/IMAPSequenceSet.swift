import Foundation

/// A set of message numbers or UIDs, such as `1:5,9,12:20`. Built from UIDs it merges runs, so a
/// command for 10,000 consecutive messages stays one short range.
public struct IMAPSequenceSet: Equatable, Sendable, CustomStringConvertible {
    public private(set) var ranges: [ClosedRange<UInt32>]

    public init(ranges: [ClosedRange<UInt32>]) { self.ranges = Self.merged(ranges) }
    public init<S: Sequence>(_ numbers: S) where S.Element == UInt32 {
        self.init(ranges: numbers.map { $0...$0 })
    }

    /// Reads a set a server sent. `*` has no value here, so a set that uses it is rejected.
    public init?(parsing text: String) {
        var ranges: [ClosedRange<UInt32>] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), let first = UInt32(ends[0]), let last = UInt32(ends[ends.count - 1]) else { return nil }
            ranges.append(min(first, last)...max(first, last))
        }
        guard !ranges.isEmpty else { return nil }
        self.init(ranges: ranges)
    }

    public var isEmpty: Bool { ranges.isEmpty }
    public var count: Int { ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 } }
    public func contains(_ number: UInt32) -> Bool { ranges.contains { $0.contains(number) } }
    /// Every number in the set, lowest first. Only for sets known to be small.
    public var numbers: [UInt32] { ranges.flatMap { Array($0) } }

    public var description: String {
        ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound):\($0.upperBound)" }.joined(separator: ",")
    }

    /// Splits into sets whose text stays under `maxLength` characters, so one command line stays
    /// within what servers accept, and that hold at most `maxCount` numbers, so one reply stays
    /// small. Chunks go from the highest numbers down, so the newest mail comes first.
    public func chunked(maxLength: Int = 900, maxCount: Int = .max) -> [IMAPSequenceSet] {
        var chunks: [IMAPSequenceSet] = []
        var current: [ClosedRange<UInt32>] = [], length = 0, count = 0
        func flush() {
            if !current.isEmpty { chunks.append(IMAPSequenceSet(ranges: current)) }
            current = []; length = 0; count = 0
        }
        for range in ranges.reversed() {
            var upper = range.upperBound
            while true {
                let room = UInt64(max(1, maxCount - count))
                let lower = UInt32(max(UInt64(range.lowerBound), UInt64(upper) >= room ? UInt64(upper) - room + 1 : 0))
                let piece = lower == upper ? "\(lower)" : "\(lower):\(upper)"
                if !current.isEmpty, length + piece.count + 1 > maxLength { flush(); continue }
                current.append(lower...upper); length += piece.count + 1; count += Int(upper - lower) + 1
                if count >= maxCount { flush() }
                guard lower > range.lowerBound else { break }
                upper = lower - 1
            }
        }
        flush()
        return chunks
    }

    private static func merged(_ ranges: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<UInt32>] = []
        for range in sorted {
            if let last = result.last, UInt64(range.lowerBound) <= UInt64(last.upperBound) + 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
