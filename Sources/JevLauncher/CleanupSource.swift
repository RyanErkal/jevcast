import AppKit
import LauncherCore

/// The cleanup checklist in the launcher. Return on an item checks or unchecks it; Return on the
/// top row stops everything checked. ⌘K offers Stop Now and Always Ignore for each item.
@MainActor
final class CleanupSource: ThingSource {
    let section = "Clean Up"
    private let preferences: Preferences
    private var cache: (at: Date, items: [Cleanup.Item])?
    /// Your changes to the checkmarks, by item key, for this session.
    private var overrides: [String: Bool] = [:]
    private let scan: (Set<String>) async -> [Cleanup.Item]
    private let stop: (Cleanup.Item) async -> String
    init(preferences: Preferences, scan: @escaping (Set<String>) async -> [Cleanup.Item] = Cleanup.scan,
         stop: @escaping (Cleanup.Item) async -> String = Cleanup.stop) {
        self.preferences = preferences; self.scan = scan; self.stop = stop
    }
    // Checking and unchecking reuse the last scan; stopping something clears it.

    func load(_ filter: String) async throws -> [LauncherResult] {
        let items: [Cleanup.Item]
        if let cache, Date().timeIntervalSince(cache.at) < 30 { items = cache.items }
        else { items = await scan(Set(preferences.cleanupIgnored)); cache = (Date(), items) }
        guard !items.isEmpty else { throw SourceProblem(text: "Nothing to clean up. No idle servers, leftover processes, or simulators are running.") }
        let checked = items.filter { $0.finding.canStop && (overrides[$0.id] ?? $0.finding.checked) }
        let freed = checked.map(\.finding.memoryMB).reduce(0, +)
        let run = Verb(title: "Clean Up", confirm: checked.contains { $0.finding.group == .computerUse }, after: .stay) { [weak self] in
            guard let self else { return nil }
            var done: [String] = []
            let before = Cleanup.availableMB()
            for item in checked { done.append(await self.stop(item)) }
            self.overrides = [:]; self.cache = nil
            // Memory comes back over a few seconds as processes exit.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let gained = Cleanup.availableMB() - before
            return done.isEmpty ? "Nothing was checked." : done.joined(separator: " · ") + (gained > 50 ? " · \(Cleanup.size(gained)) more memory free" : "")
        }
        var rows = [LauncherResult(id: "cleanup:run", title: checked.isEmpty ? "Nothing checked" : "Clean Up \(checked.count) item" + (checked.count == 1 ? "" : "s"),
                                   detail: checked.isEmpty ? "Return on an item checks it" : "Uses up to \(Cleanup.size(freed)) · T3 Code, Chrome, and apps in front keep running",
                                   symbol: "leaf", action: .thing(Thing(verbs: checked.isEmpty ? [] : [run], twoLine: false)), score: 5000)]
        let workers = items.filter { $0.finding.group == .computerUse && $0.finding.canStop }
        if !workers.isEmpty {
            let stopWorkers = Verb(title: "Stop Orphaned Computer Use Workers", confirm: true, after: .stay) { [weak self] in
                guard let self else { return nil }
                var done: [String] = []
                for item in workers { done.append(await self.stop(item)) }
                self.overrides = [:]; self.cache = nil
                return done.joined(separator: " · ")
            }
            rows.append(LauncherResult(id: "cleanup:computer-use", title: "Stop \(workers.count) Orphaned Computer Use Worker" + (workers.count == 1 ? "" : "s"),
                                       detail: "Only the workers listed below without a parent app. Attached workers and shared services stay running.",
                                       symbol: "stop.circle", action: .thing(Thing(verbs: [stopWorkers])), score: 4900))
        }
        rows += items.enumerated().map { index, item in
            let on = item.finding.canStop && (overrides[item.id] ?? item.finding.checked)
            let toggle = Verb(title: on ? "Leave Running" : "Include", after: .stay) { [weak self] in
                self?.overrides[item.id] = !on; return nil
            }
            let now = Verb(title: "Stop Now", after: .stay) { [weak self] in
                guard let self else { return nil }
                let result = await self.stop(item); self.cache = nil; return result
            }
            let ignore = Verb(title: "Always Ignore", after: .stay) { [weak self] in
                self?.preferences.cleanupIgnored.append(item.id); self?.cache = nil
                return "\(item.finding.title) will not be offered again. Settings › General lists ignored items."
            }
            let verbs = item.finding.canStop ? (item.finding.group == .computerUse ? [toggle, now] : [toggle, now, ignore]) : []
            return LauncherResult(id: "cleanup:" + item.id, title: item.finding.title,
                                  detail: [item.finding.group.title, Cleanup.size(item.finding.memoryMB), item.finding.detail].joined(separator: " · "),
                                  symbol: item.finding.canStop ? (on ? "checkmark.circle.fill" : "circle") : "lock.fill",
                                  action: .thing(Thing(verbs: verbs)), score: 4000 - Double(index))
        }
        return rows
    }
}
