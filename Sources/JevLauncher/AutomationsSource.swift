import AppKit
import LauncherCore

/// Words for automation rows, shared by the launcher sources.
@MainActor
enum AutomationText {
    static func schedule(_ a: Automation) -> String {
        switch a.schedule.rule {
        case .manual: return "Only when run"
        case .once(let date): return "Once, " + date.formatted(date: .abbreviated, time: .shortened)
        case .rrule(let text):
            guard let rule = try? RRule(text) else { return "Schedule not supported" }
            return rule.summary(anchor: a.schedule.anchor, timeZone: TimeZone(identifier: a.schedule.timeZone) ?? .current)
        }
    }

    /// "Done 2 hours ago", "Failed yesterday", "Running".
    static func lastResult(_ run: RunRecord?) -> String? {
        guard let run else { return nil }
        if run.state.isActive || run.state.needsUser { return run.state.title }
        let when = (run.finished ?? run.queued).formatted(.relative(presentation: .named))
        return "\(run.state.title) \(when)"
    }

    static func symbol(_ a: Automation, last: RunRecord?) -> String {
        if last?.state.needsUser == true { return "exclamationmark.bubble" }
        if last?.state.isActive == true { return "play.circle" }
        if last?.state == .failed { return "exclamationmark.triangle" }
        if !a.enabled { return "pause.circle" }
        return a.symbol
    }
}

/// "automations": what needs you first, then each automation with its schedule and last result.
@MainActor
final class AutomationsSource: ThingSource {
    let section = "Automations"
    private let center: AutomationCenter
    init(center: AutomationCenter) { self.center = center }

    func invalidate() { center.refresh() }

    func load(_ filter: String) async throws -> [LauncherResult] {
        let center = self.center
        let text = filter.trimmingCharacters(in: .whitespaces)
        func matches(_ title: String, _ aliases: [String] = []) -> Bool {
            text.isEmpty || SearchRanking.score(query: text, title: title, aliases: aliases) != nil
        }
        var rows: [LauncherResult] = []
        for (index, run) in center.needsYou.enumerated() where matches(run.automationName, [run.summary]) {
            let open = Verb(title: run.state == .needsInput ? "Answer" : "Review", after: .closeKeepFocus) {
                center.openWindow?(run.automationID, run.id); return nil
            }
            rows.append(LauncherResult(id: "automation-run:" + run.id, title: run.automationName,
                                       detail: [run.state.title, run.summary].filter { !$0.isEmpty }.joined(separator: " · "),
                                       symbol: "exclamationmark.bubble", action: .thing(Thing(verbs: [open])), score: 3300 - Double(index)))
        }
        if !center.runnerStatus.isRunning, !center.automations.isEmpty, text.isEmpty {
            rows.append(LauncherResult(id: "automation-runner", title: "Background runner: " + center.runnerStatus.title,
                                       detail: "Scheduled automations run only while it is on",
                                       symbol: "bolt.slash", action: .thing(Thing(verbs: [Verb(title: "Open Automations Settings") {
                                           center.openSettings?(); return nil
                                       }])), score: 3250))
        }
        for a in center.automations where matches(a.name, [a.kind.title, a.notes]) {
            let last = center.lastRun(a.id)
            var parts = [a.kind.title, AutomationText.schedule(a)]
            if !a.enabled { parts.append("paused") } else if let next = center.nextRun(a.id) {
                parts.append("next " + next.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
            }
            if let result = AutomationText.lastResult(last) { parts.append(result) }
            rows.append(LauncherResult(id: "automation:" + a.id, title: a.name, detail: parts.joined(separator: " · "),
                                       symbol: AutomationText.symbol(a, last: last),
                                       action: .thing(Thing(verbs: verbs(a, last: last), path: center.store.root.appendingPathComponent(a.id).path)),
                                       score: 3100))
        }
        for (folder, problem) in center.problems.sorted(by: { $0.key < $1.key }) where matches(folder) {
            let path = center.store.root.appendingPathComponent(folder).path
            rows.append(LauncherResult(id: "automation-problem:" + folder, title: folder, detail: "Could not read: " + problem,
                                       symbol: "exclamationmark.triangle", action: .thing(Thing(verbs: [Verb(title: "Show in Finder") {
                                           Frontmost.reveal([URL(fileURLWithPath: path)]); return nil
                                       }])), score: 3000))
        }
        if text.isEmpty || matches("New Automation") {
            rows.append(LauncherResult(id: "automation-new", title: "New Automation…", detail: "Open Automations to make one",
                                       symbol: "plus.circle", action: .thing(Thing(verbs: [Verb(title: "Open Automations") {
                                           center.openWindow?(nil, nil); return nil
                                       }])), score: 2900))
        }
        return rows
    }

    private func verbs(_ a: Automation, last: RunRecord?) -> [Verb] {
        let center = self.center
        let id = a.id, name = a.name
        var verbs: [Verb] = [
            Verb(title: "Open") { center.openWindow?(id, nil); return nil },
            Verb(title: "Run Now", after: .stay) {
                center.runNow(id)
                return center.message ?? "Asked the runner to start \(name)."
            },
            Verb(title: a.enabled ? "Pause" : "Resume", after: .stay) {
                if let problem = center.setEnabled(id, !a.enabled) { throw LauncherError(problem) }
                return a.enabled ? "Paused \(name)." : "Resumed \(name)."
            }
        ]
        if let last {
            verbs.append(Verb(title: "Open Last Result") { center.openWindow?(id, last.id); return nil })
        }
        let folder = center.store.root.appendingPathComponent(id)
        verbs.append(Verb(title: "Show in Finder") { Frontmost.reveal([folder]); return nil })
        return verbs
    }
}
