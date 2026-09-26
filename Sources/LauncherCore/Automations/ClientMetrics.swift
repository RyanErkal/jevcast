import Foundation

/// What the Clients panel shows for one Meta-ads dashboard sidecar. Plain data, no I/O.
public struct ClientMetricsSnapshot: Equatable, Sendable {
    public var clientName: String
    public var schemaVersion: Int
    public var generatedAt: Date?
    public var reportingTimeZone: String?
    /// Report range as written, "yyyy-MM-dd" in the reporting time zone.
    public var rangeStart: String?
    public var rangeEnd: String?
    public var sources: [SourceStatus]
    public var kpis: [Kpi]
    /// Anything that stops a clean read. Empty means the file matched its contract.
    public var problems: [String]

    public struct SourceStatus: Equatable, Sendable {
        public var name: String
        public var lastSuccess: Date?
        /// As written, for example "success".
        public var status: String
        public var error: String?
        /// Last closed day the source covers, "yyyy-MM-dd".
        public var closedDayThrough: String?
        public init(name: String, lastSuccess: Date?, status: String, error: String? = nil, closedDayThrough: String? = nil) {
            self.name = name; self.lastSuccess = lastSuccess; self.status = status; self.error = error; self.closedDayThrough = closedDayThrough
        }
        public func freshness(now: Date = Date()) -> MetricsFreshness { MetricsFreshness.of(self, now: now) }
    }

    public struct Kpi: Equatable, Sendable {
        public enum Format: String, Sendable { case count, currency, percent, ratio }
        public var id: String
        public var label: String
        /// Nil means not measured. Never shown as zero.
        public var value: Double?
        public var format: Format
        public var note: String?
        public init(id: String, label: String, value: Double?, format: Format, note: String? = nil) {
            self.id = id; self.label = label; self.value = value; self.format = format; self.note = note
        }
    }
}

/// Collection age of one source. Describes age only, not whether the numbers are right.
public enum MetricsFreshness: String, Sendable {
    case fresh, aging, stale, failed, unknown

    static func of(_ source: ClientMetricsSnapshot.SourceStatus, now: Date) -> MetricsFreshness {
        if source.error != nil || source.status.lowercased() != "success" { return source.status.isEmpty ? .unknown : .failed }
        guard let last = source.lastSuccess else { return .unknown }
        let age = now.timeIntervalSince(last)
        if age < 0 { return .unknown }
        if age < 6 * 3600 { return .fresh }
        if age < 24 * 3600 { return .aging }
        return .stale
    }
}

/// Explicit per-client KPI contracts. Field names match the sidecars exactly; labels keep their meaning.
public enum ClientMetricsProfile: String, Codable, CaseIterable, Sendable {
    case stein, robertParish, redesign, generic

    public var clientName: String {
        switch self {
        case .stein: return "Stein Firm"
        case .robertParish: return "Robert Parish"
        case .redesign: return "ReDesign"
        case .generic: return "Client"
        }
    }

    struct Field { var key: String; var label: String; var format: ClientMetricsSnapshot.Kpi.Format; var note: String?; var nullable = false }

    /// Required `derivedKpis` fields. Robert has no money fields by rule: its report forbids monetary metrics.
    var fields: [Field] {
        switch self {
        case .stein:
            return [Field(key: "spend", label: "Spend", format: .currency),
                    Field(key: "formQualified", label: "Form qualified", format: .count),
                    Field(key: "costPerFormQualified", label: "Cost per form qualified", format: .currency),
                    Field(key: "metaFormQualified", label: "Meta form qualified", format: .count, note: "As reported by Meta")]
        case .robertParish:
            return [Field(key: "paidSignupCount", label: "Paid signups", format: .count),
                    Field(key: "homesClicked", label: "Homes clicked", format: .count, note: "Lifecycle coverage limits apply")]
        case .redesign:
            return [Field(key: "spend", label: "Spend", format: .currency),
                    Field(key: "paidTaggedForms", label: "Paid-tagged forms", format: .count),
                    Field(key: "costPerForm", label: "Cost per form", format: .currency),
                    Field(key: "qualifiedMeetings", label: "Qualified meetings", format: .count, note: "Not measured when empty", nullable: true)]
        case .generic:
            return []
        }
    }

    public var supportedVersions: Set<Int> { self == .robertParish ? [5] : self == .generic ? [4, 5] : [4] }
}
