import AppKit
import LauncherCore

/// Words and symbols shared by the dashboard card, Settings, and launcher rows.
enum DashboardDisplay {
    static func freshness(_ entry: AutomationCenter.DashboardEntry, now: Date = Date()) -> DashboardFreshness {
        DashboardFreshness.of(entry.snapshot?.updatedAt, now: now)
    }

    static func freshnessText(_ entry: AutomationCenter.DashboardEntry, now: Date = Date()) -> String? {
        guard let updated = entry.snapshot?.updatedAt else { return nil }
        let age = "updated " + updated.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        switch freshness(entry, now: now) {
        case .aging: return "Aging, " + age
        case .stale: return "Stale, " + age
        default: return age.prefix(1).uppercased() + age.dropFirst()
        }
    }

    static func symbol(_ entry: AutomationCenter.DashboardEntry) -> String {
        guard entry.readError == nil, let snapshot = entry.snapshot, snapshot.problems.isEmpty else { return "exclamationmark.triangle" }
        return freshness(entry) == .stale ? "clock" : "chart.bar.xaxis"
    }

    /// The first thing wrong with a card, if anything.
    static func problem(_ entry: AutomationCenter.DashboardEntry) -> String? {
        if let error = entry.readError { return entry.snapshot == nil ? error : "Showing the last good read. " + error }
        if entry.config.metrics.isEmpty { return entry.config.note ?? "No numbers chosen yet." }
        return entry.snapshot?.problems.first
    }
}

/// "dashboards" (also "clients" and "metrics"): each card's numbers, with freshness.
@MainActor
final class DashboardsSource: ThingSource {
    let section = "Dashboards"
    private let center: AutomationCenter
    init(center: AutomationCenter) { self.center = center }

    func load(_ filter: String) async throws -> [LauncherResult] {
        await center.readDashboardsNow()
        let entries = center.dashboards.filter { filter.isEmpty || SearchRanking.score(query: filter, title: $0.config.name) != nil }
        guard !entries.isEmpty else {
            throw SourceProblem(text: center.dashboards.isEmpty ? "No dashboards yet. Add one in Settings › Automations › Dashboards." : "No dashboard matches.")
        }
        return entries.enumerated().map { index, entry in
            var parts: [String] = []
            if let snapshot = entry.snapshot {
                let summary = DashboardText.summary(snapshot)
                if !summary.isEmpty { parts.append(summary) }
                if let fresh = DashboardDisplay.freshnessText(entry) { parts.append(fresh) }
            } else if entry.readError == nil { parts.append("Not read yet") }
            if let problem = DashboardDisplay.problem(entry) { parts.append(problem) }
            return LauncherResult(id: "dashboard:" + entry.id, title: entry.config.name, detail: parts.joined(separator: " · "),
                                  symbol: DashboardDisplay.symbol(entry),
                                  action: .thing(Thing(verbs: verbs(entry), path: entry.config.filePath)), score: 3000 - Double(index))
        }
    }

    private func verbs(_ entry: AutomationCenter.DashboardEntry) -> [Verb] {
        let center = self.center
        let id = entry.id, name = entry.config.name
        var verbs: [Verb] = []
        if entry.config.openPath != nil {
            verbs.append(Verb(title: "Open File") { center.openDashboardFile(id); return nil })
        }
        verbs.append(Verb(title: "Refresh Now", after: .stay) {
            center.refreshDashboard(id)
            return entry.config.automationID == nil ? "Read \(name) again. No refresh automation is set." : "Asked the runner to refresh \(name)."
        })
        verbs.append(Verb(title: "Open in Automations") { center.openWindow?(entry.config.automationID, nil); return nil })
        verbs.append(Verb(title: "Show Data File in Finder") { Frontmost.reveal([URL(fileURLWithPath: entry.config.filePath)]); return nil })
        return verbs
    }
}
