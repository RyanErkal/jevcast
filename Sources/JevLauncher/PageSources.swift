import AppKit
import SwiftUI
import LauncherCore

/// The Tasks view: scheduled Quill tasks first, then their recent results.
@MainActor
final class QuillTasksPageSource: ThingSource {
    let section = "Tasks"
    private let center: QuillTaskCenter
    private let runs: TaskRunsSource
    init(center: QuillTaskCenter, openRun: @escaping (QuillTaskRun) -> Void) {
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
            return LauncherResult(id: QuillStorageKeys.taskRowPrefix + task.id, title: task.name, detail: parts.joined(separator: " · "),
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

/// Makes each view. Snapshot runs get empty Mail, Calendar, and Clean Up views, so a capture
/// never shows real mail, events, or processes.
@MainActor
enum LauncherPages {
    struct Links {
        var mail: (() -> MailModel)?
        var mailWindow: ((Int64?) -> Void)?
        var runWindow: ((QuillTaskRun) -> Void)?
    }

    static func make(_ id: ViewID, model: LauncherModel, links: Links, snapshot: Bool) -> LauncherPage? {
        switch id {
        case .mail:
            return MailPage(mail: snapshot ? nil : links.mail?(), popOut: links.mailWindow)
        case .calendar:
            let list = SourcePage(.calendar, source: snapshot ? nil : CalendarSource(), model: model, scope: "week", hasDetail: true,
                                  emptyText: "Nothing in the next seven days.",
                                  popOut: snapshot ? nil : { [weak model] in model?.onClose?(false); CalendarSource.openApp("com.apple.iCal") })
            return CalendarPage(list: list, readsEvents: !snapshot)
        case .tasks:
            let center = model.quillTasks
            let openRun = links.runWindow ?? { _ in }
            let texts = ResultTexts()
            return SourcePage(.tasks, source: QuillTasksPageSource(center: center, openRun: openRun), model: model, hasDetail: true,
                              emptyText: "No scheduled tasks yet.", detailBody: { row in
                guard row.id.hasPrefix(QuillStorageKeys.runRowPrefix), let run = center.runs.first(where: { QuillStorageKeys.runRowPrefix + $0.id == row.id }) else { return nil }
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
        }
    }
}

/// Task result text by run, read from its file once.
@MainActor
private final class ResultTexts {
    private var cache: [String: String] = [:]
    func text(for run: QuillTaskRun) -> String {
        if let cached = cache[run.id] { return cached }
        let text = run.file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? run.preview
        cache[run.id] = text
        return text
    }
}
