import AppKit
import SwiftUI
import LauncherCore

/// One task result, opened from its notification or the launcher.
@MainActor
final class ScheduledBriefResultWindow: NSWindowController {
    init(run: ScheduledBriefRun) {
        let text = run.file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? run.preview
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = run.taskName
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ScheduledBriefResultView(run: run, text: text))
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() { showWindow(nil); if let window { Frontmost.show(window) } }
}

struct ScheduledBriefResultView: View {
    let run: ScheduledBriefRun
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(run.date.formatted(date: .abbreviated, time: .shortened), systemImage: run.succeeded ? "sparkles" : "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copyText(text) }
                if let file = run.file {
                    Button("Show in Finder") { Frontmost.reveal([URL(fileURLWithPath: file)]) }
                }
            }
            .font(.callout)
            ScrollView {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
    }
}

/// Settings › AI › Writing: the scheduled tasks and their last results.
struct ScheduledBriefSettings: View {
    @ObservedObject var center: ScheduledBriefCenter
    var body: some View {
        if center.tasks.isEmpty {
            Text("No scheduled briefs. Type one in the launcher, such as “every weekday at 8am brief me on my meetings and unread email”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(center.tasks) { task in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Toggle(task.name, isOn: Binding(get: { task.enabled }, set: { center.setEnabled(task.id, $0) }))
                    Spacer()
                    Button(center.running.contains(task.id) ? "Running…" : "Run Now") { center.run(task) }
                        .controlSize(.small).disabled(center.running.contains(task.id))
                    Button("Delete", role: .destructive) { center.remove(task.id) }.controlSize(.small)
                }
                Text(details(task)).font(.caption).foregroundStyle(center.refused(task).isEmpty ? Color.secondary : Color.orange)
            }
        }
        Button("Open Results Folder") {
            try? FileManager.default.createDirectory(at: ScheduledBriefCenter.folder, withIntermediateDirectories: true)
            Frontmost.open(ScheduledBriefCenter.folder)
        }
        .controlSize(.small)
    }
    private func details(_ task: ScheduledBrief) -> String {
        var parts = [task.schedule.summary]
        if !task.contexts.isEmpty { parts.append("reads " + task.contexts.map(\.title).joined(separator: ", ").lowercased()) }
        let refused = center.refused(task)
        if !refused.isEmpty { parts.append("turn on " + refused.map(\.title).joined(separator: " and ").lowercased() + " below") }
        if let last = center.lastRun(of: task.id) { parts.append("last run " + last.date.formatted(.relative(presentation: .named)) + (last.succeeded ? "" : ", failed")) }
        return parts.joined(separator: " · ")
    }
}
