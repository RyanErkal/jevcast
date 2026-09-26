import Foundation

public enum ClientMetricsError: Error, Equatable, Sendable {
    case unreadable
    case tooLarge
    case notJSONObject
}

/// Reads one metrics sidecar. One open file descriptor, so an atomic replace mid-read cannot mix two versions.
public enum ClientMetricsReader {
    public static let maxBytes = 10 * 1024 * 1024

    public static func read(url: URL, profile: ClientMetricsProfile) throws -> ClientMetricsSnapshot {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ClientMetricsError.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ClientMetricsError.unreadable }
        guard st.st_size <= maxBytes else { throw ClientMetricsError.tooLarge }
        guard let data = try handle.read(upToCount: maxBytes + 1) else { throw ClientMetricsError.unreadable }
        guard data.count <= maxBytes else { throw ClientMetricsError.tooLarge }
        return try decode(data, profile: profile)
    }

    public static func decode(_ data: Data, profile: ClientMetricsProfile) throws -> ClientMetricsSnapshot {
        guard data.count <= maxBytes else { throw ClientMetricsError.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClientMetricsError.notJSONObject }
        var problems: [String] = []
        let version = int(root["schemaVersion"]) ?? -1
        var snap = ClientMetricsSnapshot(clientName: profile.clientName, schemaVersion: version, generatedAt: nil, reportingTimeZone: nil,
                                         rangeStart: nil, rangeEnd: nil, sources: [], kpis: [], problems: [])
        guard profile.supportedVersions.contains(version) else {
            snap.problems = ["Unsupported schema version \(version)"]
            return snap
        }
        snap.generatedAt = date(root["generatedAt"])
        if snap.generatedAt == nil { problems.append("generatedAt is missing or invalid") }
        if let tz = root["reportingTimezone"] as? String, TimeZone(identifier: tz) != nil {
            snap.reportingTimeZone = tz
        } else { problems.append("reportingTimezone is missing or invalid") }
        if let range = root["reportRange"] as? [String: Any], let from = day(range["from"]), let to = day(range["to"]), from <= to {
            snap.rangeStart = from; snap.rangeEnd = to
        } else { problems.append("reportRange is missing or invalid") }
        snap.sources = sources(root["sourceFreshness"], problems: &problems)
        snap.kpis = kpis(root["derivedKpis"], profile: profile, problems: &problems)
        snap.problems = problems
        return snap
    }

    private static func sources(_ raw: Any?, problems: inout [String]) -> [ClientMetricsSnapshot.SourceStatus] {
        guard let list = raw as? [[String: Any]] else { problems.append("sourceFreshness is missing"); return [] }
        return list.compactMap { s in
            guard let name = s["source"] as? String, !name.isEmpty else { problems.append("A source has no name"); return nil }
            let lastRaw = s["last_success_at"]
            let last = date(lastRaw)
            if lastRaw != nil, !(lastRaw is NSNull), last == nil { problems.append("\(name): last_success_at is invalid") }
            let error = (s["last_error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .init(name: name, lastSuccess: last, status: s["last_status"] as? String ?? "",
                         error: error, closedDayThrough: day(s["closed_day_through"]))
        }
    }

    private static func kpis(_ raw: Any?, profile: ClientMetricsProfile, problems: inout [String]) -> [ClientMetricsSnapshot.Kpi] {
        guard let dict = raw as? [String: Any] else { problems.append("derivedKpis is missing"); return [] }
        return profile.fields.map { f in
            let rawValue = dict[f.key]
            let value = number(rawValue)
            if value == nil {
                let isNull = rawValue is NSNull
                if rawValue == nil { problems.append("\(f.key) is missing") }
                else if !isNull { problems.append("\(f.key) is not a finite number") }
                else if !f.nullable { problems.append("\(f.key) is empty") }
            }
            return .init(id: f.key, label: f.label, value: value, format: f.format, note: f.note)
        }
    }

    // MARK: Values

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func int(_ v: Any?) -> Int? {
        guard let d = number(v), d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func day(_ v: Any?) -> String? {
        guard let s = v as? String, s.count == 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) == nil ? nil : s
    }
}
