import AppKit
import LauncherCore

/// "task results": what scheduled Luna tasks wrote, newest first.
@MainActor
final class TaskRunsSource: ThingSource {
    let section = "Task Results"
    private let tasks: LunaTaskCenter
    private let openRun: (LunaTaskRun) -> Void
    init(tasks: LunaTaskCenter, openRun: @escaping (LunaTaskRun) -> Void) { self.tasks = tasks; self.openRun = openRun }

    func load(_ filter: String) async throws -> [LauncherResult] {
        let runs = filter.isEmpty ? tasks.runs : tasks.runs.filter { SearchRanking.score(query: filter, title: $0.taskName, aliases: [$0.preview]) != nil }
        guard !runs.isEmpty else { throw SourceProblem(text: tasks.tasks.isEmpty ? "No scheduled tasks yet. Try “every morning brief me on my meetings”." : "No results yet.") }
        let openRun = self.openRun
        return runs.prefix(60).enumerated().map { index, run in
            var verbs = [Verb(title: "Open Result") { openRun(run); return nil }]
            let preview = run.preview
            verbs.append(Verb(title: "Copy Result", after: .stay) {
                copyText(run.file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? preview); return "Result copied."
            })
            if let file = run.file {
                verbs.append(Verb(title: "Show in Finder") { Frontmost.reveal([URL(fileURLWithPath: file)]); return nil })
            }
            return LauncherResult(id: "lunarun:" + run.id, title: run.taskName,
                                  detail: run.date.formatted(.relative(presentation: .named)) + " · " + preview,
                                  symbol: run.succeeded ? "doc.text" : "exclamationmark.triangle", action: .thing(Thing(verbs: verbs)), score: 3000 - Double(index))
        }
    }
}
