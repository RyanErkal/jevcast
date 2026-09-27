import Foundation

public enum DashboardReadError: Error, Equatable, Sendable {
    case unreadable
    case tooLarge
    case notJSON
}

/// Reads a dashboard's JSON file and finds values by key path. One open file descriptor, so an atomic
/// replace during a read cannot mix two versions. Never runs or fetches anything.
public enum DashboardReader {
    public static let maxBytes = 10 * 1024 * 1024

    public static func read(url: URL, config: DashboardConfig) throws -> DashboardSnapshot {
        snapshot(try load(url: url), config: config)
    }

    /// The parsed JSON of a file, bounded in size. Only regular files are read.
    public static func load(url: URL) throws -> Any {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw DashboardReadError.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw DashboardReadError.unreadable }
        guard st.st_size <= maxBytes else { throw DashboardReadError.tooLarge }
        guard let data = try handle.read(upToCount: maxBytes + 1) else { throw DashboardReadError.unreadable }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Any {
        guard data.count <= maxBytes else { throw DashboardReadError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw DashboardReadError.notJSON }
        return root
    }

    public static func snapshot(_ root: Any, config: DashboardConfig) -> DashboardSnapshot {
        var problems: [String] = []
        let readings = config.metrics.map { metric -> DashboardSnapshot.Reading in
            let found = lookup(metric.keyPath, in: root)
            let value = found.flatMap(leaf)
            if found == nil { problems.append("\(metric.keyPath) is not in the file") }
            return .init(metric: metric, value: value)
        }
        var updated: Date?
        if let path = config.updatedAtKeyPath, !path.isEmpty {
            updated = lookup(path, in: root).flatMap(date)
            if updated == nil { problems.append("\(path) is not a date") }
        }
        return DashboardSnapshot(readings: readings, updatedAt: updated, problems: problems)
    }

    // MARK: Key paths

    public static func segments(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    /// The raw JSON value at a key path, or nil when any step is missing.
    public static func lookup(_ path: String, in root: Any) -> Any? {
        let parts = segments(path.trimmingCharacters(in: .whitespaces))
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        var current: Any = root
        for part in parts {
            if let dict = current as? [String: Any], let next = dict[part] { current = next }
            else if let list = current as? [Any], let index = Int(part), list.indices.contains(index) { current = list[index] }
            else { return nil }
        }
        return current
    }

    /// Numbers, strings, and true or false. Null, objects, and arrays are not values.
    public static func leaf(_ raw: Any) -> DashboardValue? {
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            return d.isFinite ? .number(d) : nil
        }
        if let s = raw as? String { return .text(s) }
        return nil
    }

    /// A leaf the metric picker offers, with a short preview of its value.
    public struct LeafPath: Equatable, Hashable, Sendable {
        public var path: String
        public var value: DashboardValue
    }

    /// Number, text, and true-or-false leaves, depth first in key order. Bounded in count, depth, and array items,
    /// so a large file cannot flood the picker. Keys with a dot cannot be written as a path and are skipped.
    public static func leafPaths(in root: Any, limit: Int = 300, maxDepth: Int = 8, maxArrayItems: Int = 5) -> [LeafPath] {
        var out: [LeafPath] = []
        func walk(_ node: Any, _ prefix: [String]) {
            guard out.count < limit, prefix.count <= maxDepth else { return }
            if let dict = node as? [String: Any] {
                for key in dict.keys.sorted() where !key.contains(".") && !key.isEmpty { walk(dict[key]!, prefix + [key]) }
            } else if let list = node as? [Any] {
                for (i, item) in list.prefix(maxArrayItems).enumerated() { walk(item, prefix + [String(i)]) }
            } else if !prefix.isEmpty, let value = leaf(node) {
                out.append(.init(path: prefix.joined(separator: "."), value: value))
            }
        }
        walk(root, [])
        return out
    }

    // MARK: Values

    /// ISO 8601 text, a `yyyy-MM-dd` day, or seconds since 1970 (milliseconds when very large).
    public static func date(_ raw: Any) -> Date? {
        if let s = raw as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withFullDate]
            return s.count == 10 ? f.date(from: s) : nil
        }
        if case .number(let n)? = leaf(raw), n > 0 {
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        }
        return nil
    }
}

/// Words for dashboard values.
public enum DashboardText {
    public static func value(_ value: DashboardValue?, metric: DashboardMetric) -> String {
        guard let value else { return "Not set" }
        switch value {
        case .text(let s): return s.isEmpty ? "Empty" : s
        case .bool(let b): return b ? "Yes" : "No"
        case .number(let n): return number(n, metric: metric)
        }
    }

    static func number(_ n: Double, metric: DashboardMetric) -> String {
        switch metric.format {
        case .number, .text:
            return n.formatted(.number.precision(.fractionLength(n == n.rounded() ? 0 : 2)))
        case .currency:
            let symbol = (metric.currencySymbol?.isEmpty == false ? metric.currencySymbol! : "$")
            let body = abs(n).formatted(.number.precision(.fractionLength(abs(n) >= 100 ? 0 : 2)))
            return (n < 0 ? "-" : "") + symbol + body
        case .percent:
            return n.formatted(.number.precision(.fractionLength(1))) + "%"
        case .duration:
            return duration(n)
        }
    }

    /// Seconds as "45s", "12m 5s", "3h 20m", or "2d 4h".
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, let s = Int(exactly: abs(seconds).rounded()) else { return "Out of range" }
        let sign = seconds < 0 ? "-" : ""
        switch s {
        case ..<60: return sign + "\(s)s"
        case ..<3600: return sign + "\(s / 60)m" + (s % 60 == 0 ? "" : " \(s % 60)s")
        case ..<86400: return sign + "\(s / 3600)h" + ((s % 3600) / 60 == 0 ? "" : " \((s % 3600) / 60)m")
        default: return sign + "\(s / 86400)d" + ((s % 86400) / 3600 == 0 ? "" : " \((s % 86400) / 3600)h")
        }
    }

    public static func preview(_ value: DashboardValue) -> String {
        switch value {
        case .number(let n): return n.formatted(.number.precision(.fractionLength(0...2)))
        case .text(let s): return s.count > 32 ? String(s.prefix(31)) + "…" : s
        case .bool(let b): return b ? "true" : "false"
        }
    }

    /// "Label value · Label value" for launcher rows.
    public static func summary(_ snapshot: DashboardSnapshot) -> String {
        snapshot.readings.map { "\($0.metric.label) \(value($0.value, metric: $0.metric))" }.joined(separator: " · ")
    }
}
