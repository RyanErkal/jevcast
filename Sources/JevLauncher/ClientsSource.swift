import AppKit
import LauncherCore

/// Words for client metrics. KPI labels come from the profile as they are; they are never renamed.
enum ClientMetricsText {
    static func value(_ kpi: ClientMetricsSnapshot.Kpi) -> String {
        guard let v = kpi.value else { return "not measured" }
        switch kpi.format {
        case .currency: return "$" + v.formatted(.number.precision(.fractionLength(v >= 100 ? 0 : 2)))
        case .percent: return v.formatted(.number.precision(.fractionLength(1))) + "%"
        case .ratio: return v.formatted(.number.precision(.fractionLength(2)))
        case .count: return v.formatted(.number.precision(.fractionLength(0)))
        }
    }

    static func kpis(_ snapshot: ClientMetricsSnapshot) -> String {
        snapshot.kpis.map { "\($0.label) \(value($0))" }.joined(separator: " · ")
    }

    /// The oldest source decides: one failed or stale source makes the whole client stale.
    static func freshness(_ snapshot: ClientMetricsSnapshot, now: Date = Date()) -> MetricsFreshness {
        let order: [MetricsFreshness] = [.failed, .unknown, .stale, .aging, .fresh]
        let all = snapshot.sources.map { $0.freshness(now: now) }
        guard !all.isEmpty else { return .unknown }
        return order.first { all.contains($0) } ?? .unknown
    }

    static func freshnessText(_ snapshot: ClientMetricsSnapshot, now: Date = Date()) -> String {
        let state = freshness(snapshot, now: now)
        let oldest = snapshot.sources.compactMap(\.lastSuccess).min()
        let age = oldest.map { "collected " + $0.formatted(.relative(presentation: .named)) } ?? "collection time unknown"
        switch state {
        case .fresh: return age
        case .aging: return "aging, " + age
        case .stale: return "stale, " + age
        case .failed: return "a source failed"
        case .unknown: return "freshness unknown"
        }
    }

    static func symbol(_ entry: AutomationCenter.ClientEntry) -> String {
        guard let snapshot = entry.snapshot, entry.readError == nil, snapshot.problems.isEmpty else { return "exclamationmark.triangle" }
        switch freshness(snapshot) {
        case .fresh: return "chart.bar.xaxis"
        case .aging: return "clock"
        default: return "exclamationmark.triangle"
        }
    }
}

/// "clients", "metrics", "meta ads": each client's KPIs from its sidecar, with freshness.
@MainActor
final class ClientsSource: ThingSource {
    let section = "Clients"
    private let center: AutomationCenter
    init(center: AutomationCenter) { self.center = center }

    func load(_ filter: String) async throws -> [LauncherResult] {
        await center.readClientsNow()
        let entries = center.clients.filter { filter.isEmpty || SearchRanking.score(query: filter, title: $0.config.name) != nil }
        guard !entries.isEmpty else {
            throw SourceProblem(text: center.clients.isEmpty ? "No clients yet. Add one in Settings › Automations › Clients." : "No client matches.")
        }
        return entries.enumerated().map { index, entry in
            var parts: [String] = []
            if let snapshot = entry.snapshot {
                if !snapshot.problems.isEmpty, snapshot.kpis.isEmpty { parts.append(snapshot.problems.first ?? "Unsupported") }
                else {
                    let kpis = ClientMetricsText.kpis(snapshot)
                    if !kpis.isEmpty { parts.append(kpis) }
                    if let from = snapshot.rangeStart, let to = snapshot.rangeEnd { parts.append(from == to ? from : "\(from) to \(to)") }
                    parts.append(ClientMetricsText.freshnessText(snapshot))
                }
            } else { parts.append("No metrics read yet") }
            if let error = entry.readError { parts.append(entry.snapshot == nil ? error : "showing last good read: " + error) }
            return LauncherResult(id: "client:" + entry.id, title: entry.config.name, detail: parts.joined(separator: " · "),
                                  symbol: ClientMetricsText.symbol(entry),
                                  action: .thing(Thing(verbs: verbs(entry), path: entry.config.metricsPath)), score: 3000 - Double(index))
        }
    }

    private func verbs(_ entry: AutomationCenter.ClientEntry) -> [Verb] {
        let center = self.center
        let id = entry.id, name = entry.config.name
        var verbs: [Verb] = []
        if entry.config.dashboardPath != nil {
            verbs.append(Verb(title: "Open Dashboard") { center.openDashboard(id); return nil })
        }
        verbs.append(Verb(title: "Refresh Now", after: .stay) {
            center.refreshClient(id)
            return entry.config.automationID == nil ? "Read \(name)'s metrics again. No refresh automation is set." : "Asked the runner to refresh \(name)."
        })
        verbs.append(Verb(title: "Open in Automations") { center.openWindow?(entry.config.automationID, nil); return nil })
        verbs.append(Verb(title: "Show Metrics File in Finder") { Frontmost.reveal([URL(fileURLWithPath: entry.config.metricsPath)]); return nil })
        return verbs
    }
}
