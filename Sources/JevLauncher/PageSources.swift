import AppKit
import SwiftUI
import LauncherCore

/// The Tasks view: scheduled briefs first, then their recent results.
@MainActor
final class ScheduledBriefsPageSource: ThingSource {
    let section = "Tasks"
    private let center: ScheduledBriefCenter
    private let runs: TaskRunsSource
    init(center: ScheduledBriefCenter, openRun: @escaping (ScheduledBriefRun) -> Void) {
        self.center = center
        runs = TaskRunsSource(tasks: center, openRun: openRun)
    }

    func load(_ filter: String) async throws -> [LauncherResult] {
        let tasks = center.tasks.enumerated().map { index, task in
            let running = center.running.contains(task.id)
            let run = Verb(title: running ? "Running…" : "Run Now", after: .stay) { [center] in
                center.run(task); return "Running \(task.name). The result shows here when it is done."
            }
            let toggle = Verb(title: task.enabled ? "Turn Off" : "Turn On", after: .stay) { [center] in
                center.setEnabled(task.id, !task.enabled); return nil
            }
            var parts = [task.enabled ? task.schedule.summary : "Off"]
            if let last = center.lastRun(of: task.id) { parts.append("last run " + last.date.formatted(.relative(presentation: .named))) }
            return LauncherResult(id: AIWritingStorageKeys.taskRowPrefix + task.id, title: task.name, detail: parts.joined(separator: " · "),
                                  symbol: task.enabled ? "clock" : "clock.badge.xmark", action: .thing(Thing(verbs: [run, toggle])),
                                  score: 5000 - Double(index))
        }
        let results = (try? await runs.load("")) ?? []
        guard !tasks.isEmpty || !results.isEmpty else {
            throw SourceProblem(text: "No scheduled tasks yet. Type one in the launcher, such as “every morning brief me on my meetings”.")
        }
        return tasks + results
    }
}

/// Makes each view. Snapshot runs get empty Mail, Calendar, Clean Up, and Tailnet views, so a capture
/// never shows real mail, events, processes, or devices. Demo snapshots show invented devices.
@MainActor
enum LauncherPages {
    struct Links {
        var mail: (() -> MailModel)?
        var runWindow: ((ScheduledBriefRun) -> Void)?
        /// The running shell, or a new one. Nil when libghostty cannot start.
        var terminal: (() -> TerminalView?)?
    }

    static func make(_ id: ViewID, model: LauncherModel, links: Links, snapshot: Bool) -> LauncherPage? {
        switch id {
        case .mail:
            return MailPage(mail: snapshot ? nil : links.mail?(), focusFilter: { [weak model] in model?.focusInput() })
        case .calendar:
            let list = SourcePage(.calendar, source: snapshot ? nil : CalendarSource(), model: model, scope: "week", hasDetail: true,
                                  emptyText: "Nothing in the next seven days.",
                                  popOut: snapshot ? nil : { [weak model] in model?.onClose?(false); CalendarSource.openApp("com.apple.iCal") })
            return CalendarPage(list: list, readsEvents: !snapshot, hideLauncher: { [weak model] in model?.onClose?(false) })
        case .tasks:
            let center = model.scheduledBriefs
            let openRun = links.runWindow ?? { _ in }
            let texts = ResultTexts()
            return SourcePage(.tasks, source: ScheduledBriefsPageSource(center: center, openRun: openRun), model: model, hasDetail: true,
                              emptyText: "No scheduled tasks yet.", detailBody: { row in
                guard row.id.hasPrefix(AIWritingStorageKeys.runRowPrefix), let run = center.runs.first(where: { AIWritingStorageKeys.runRowPrefix + $0.id == row.id }) else { return nil }
                // Read each result file once, not on every redraw.
                let text = texts.text(for: run)
                return AnyView(ScrollView {
                    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                        .font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                })
            })
        case .clipboard:
            return ClipboardPage(history: model.clipboard, model: model)
        case .cleanup:
            return SourcePage(.cleanup, source: snapshot ? nil : CleanupSource(preferences: model.preferences), model: model, hasDetail: false,
                              emptyText: "Nothing to clean up. No idle servers, leftover processes, or simulators are running.")
        case .terminal:
            // Snapshots never start a shell.
            return TerminalPage(terminal: snapshot ? nil : links.terminal?(),
                                placeholder: snapshot ? "Your login shell runs here." : "The terminal could not start.")
        case .tailnet:
            // The search's source, so pages, icons, and pings carry over between views.
            let source = snapshot ? (DemoData.isEnabled ? TailnetSource(preferences: model.preferences, reader: DemoTailnet(), checks: { true }) : nil)
                : model.source(.tailnet) as? TailnetSource
            return SourcePage(.tailnet, source: source, model: model, hasDetail: false, emptyText: "No tailnet devices.",
                              refreshEvery: snapshot ? nil : 5, rowIcon: { [weak source] row in source?.icon(for: row.id) })
        }
    }
}

/// Task result text by run, read from its file once.
@MainActor
private final class ResultTexts {
    private var cache: [String: String] = [:]
    func text(for run: ScheduledBriefRun) -> String {
        if let cached = cache[run.id] { return cached }
        let text = run.file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? run.preview
        cache[run.id] = text
        return text
    }
}
