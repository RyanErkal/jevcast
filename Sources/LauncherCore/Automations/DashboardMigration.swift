import Foundation

/// Turns the old `clients.json` (fixed metrics profiles) into generic dashboards. The old file stays in place.
public enum DashboardMigration {
    public static let unknownNote = "Moved from an older version. Choose Edit to add the numbers to show."

    public struct LegacyClient: Decodable, Sendable {
        var id: String
        var name: String
        var profile: String?
        var metricsPath: String
        var dashboardPath: String?
        var automationID: String?
    }

    /// Each old profile's KPIs as key paths in its metrics file. Labels and formats are as the old app showed them.
    static let legacyFields: [String: [(key: String, label: String, format: DashboardFormat)]] = [
        "stein": [("spend", "Spend", .currency), ("formQualified", "Form qualified", .number),
                  ("costPerFormQualified", "Cost per form qualified", .currency), ("metaFormQualified", "Meta form qualified", .number)],
        "robertParish": [("paidSignupCount", "Paid signups", .number), ("homesClicked", "Homes clicked", .number)],
        "redesign": [("spend", "Spend", .currency), ("paidTaggedForms", "Paid-tagged forms", .number),
                     ("costPerForm", "Cost per form", .currency), ("qualifiedMeetings", "Qualified meetings", .number)]
    ]

    /// Refuse the whole migration if any entry is unreadable. Never persist a partial list.
    public static func migrate(legacy data: Data) -> [DashboardConfig]? {
        guard let list = try? JSONDecoder().decode([LegacyClient].self, from: data) else { return nil }
        return migrate(list)
    }

    public static func migrate(_ list: [LegacyClient]) -> [DashboardConfig] { list.map(migrate) }

    static func migrate(_ old: LegacyClient) -> DashboardConfig {
        let fields = old.profile.flatMap { legacyFields[$0] }
        let metrics = (fields ?? []).map {
            DashboardMetric(id: old.id + "." + $0.key, label: $0.label, keyPath: "derivedKpis." + $0.key, format: $0.format,
                            currencySymbol: $0.format == .currency ? "$" : nil)
        }
        return DashboardConfig(id: old.id, name: old.name, filePath: old.metricsPath, metrics: metrics,
                               updatedAtKeyPath: fields == nil ? nil : "generatedAt",
                               automationID: old.automationID, openPath: old.dashboardPath,
                               note: fields == nil ? unknownNote : nil)
    }
}
