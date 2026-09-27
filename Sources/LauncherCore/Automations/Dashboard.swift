import Foundation

/// A dashboard card: numbers read from one local JSON file the user picks. Stored in `Automations/dashboards.json`.
public struct DashboardConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The JSON file to read.
    public var filePath: String
    public var metrics: [DashboardMetric]
    /// Key path of a date that says when the file's data was made, for freshness.
    public var updatedAtKeyPath: String?
    /// The automation that "Refresh Now" runs.
    public var automationID: String?
    /// A file to open from the card, such as an HTML report.
    public var openPath: String?
    /// A short note shown on the card, for example after a migration.
    public var note: String?

    public init(id: String, name: String, filePath: String, metrics: [DashboardMetric] = [], updatedAtKeyPath: String? = nil,
                automationID: String? = nil, openPath: String? = nil, note: String? = nil) {
        self.id = id; self.name = name; self.filePath = filePath; self.metrics = metrics
        self.updatedAtKeyPath = updatedAtKeyPath; self.automationID = automationID; self.openPath = openPath; self.note = note
    }
}

public struct DashboardMetric: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    /// Dot-separated keys; a number picks an array item, for example `totals.spend` or `sources.0.status`.
    public var keyPath: String
    public var format: DashboardFormat
    /// Used by the currency format. Defaults to "$".
    public var currencySymbol: String?

    public init(id: String = UUID().uuidString, label: String, keyPath: String, format: DashboardFormat, currencySymbol: String? = nil) {
        self.id = id; self.label = label; self.keyPath = keyPath; self.format = format; self.currencySymbol = currencySymbol
    }
}

public enum DashboardFormat: String, Codable, CaseIterable, Sendable {
    case number, currency, percent, duration, text

    public var title: String {
        switch self {
        case .number: return "Number"
        case .currency: return "Currency"
        case .percent: return "Percent"
        case .duration: return "Duration (seconds)"
        case .text: return "Text"
        }
    }
}

/// A value found in the file.
public enum DashboardValue: Equatable, Hashable, Sendable {
    case number(Double)
    case text(String)
    case bool(Bool)
}

/// What a card shows after one read. Plain data.
public struct DashboardSnapshot: Equatable, Sendable {
    public struct Reading: Equatable, Sendable {
        public var metric: DashboardMetric
        /// Nil when the key path is missing or empty. Never shown as zero.
        public var value: DashboardValue?
    }
    public var readings: [Reading]
    public var updatedAt: Date?
    /// Key paths that were not found, and similar problems.
    public var problems: [String]
}

/// How old the data is, from the "updated at" key path.
public enum DashboardFreshness: String, Sendable {
    case fresh, aging, stale, unknown

    public static func of(_ updatedAt: Date?, now: Date = Date()) -> DashboardFreshness {
        guard let updatedAt else { return .unknown }
        let age = now.timeIntervalSince(updatedAt)
        if age < -300 { return .unknown }
        if age < 6 * 3600 { return .fresh }
        if age < 24 * 3600 { return .aging }
        return .stale
    }
}
