import SwiftUI
import LauncherCore

/// Quill: the writing model for answers, rewrites, and mail. Every kind of context has its own switch.
struct QuillSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var log: QuillActivityLog
    @ObservedObject var jevKeys: JevKeyCache
    @ObservedObject var quillKeys: JevKeyCache
    let tasks: QuillTaskCenter
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var showsActivity = false

    private var usesJevKey: Bool {
        if case .present(let value) = jevKeys.state, value.hasPrefix("sk-or-"), !quillKeys.hasKey { return true }
        return false
    }
    private var hasKey: Bool { usesJevKey || quillKeys.hasKey }

    var body: some View {
        Group {
            Section("Quill") {
                Toggle("Use Quill for answers and writing", isOn: $preferences.quillEnabled)
                InfoCaption("Writes text. Never runs actions.",
                            detail: "Jev decides what a request means. Quill, the chosen model through OpenRouter, writes text when a request needs it: “ask …”, rewrites of selected text, and mail summaries and replies. Quill never runs actions.")
                Picker("Model", selection: $preferences.quillModel) {
                    ForEach(QuillModel.catalog) { Text($0.title).tag($0.id) }
                }
                Picker("Reasoning effort", selection: $preferences.quillEffort) {
                    ForEach(ReasoningEffort.quillChoices, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Low answers in seconds. Higher efforts think longer and cost more.").font(.caption).foregroundStyle(.secondary)
                Toggle("Fast", isOn: $preferences.quillFast)
                Text("Faster replies. Uses more credits.").font(.caption).foregroundStyle(.secondary)
            }
            Section("OpenRouter key") {
                if usesJevKey {
                    LabeledContent("Key") { Text("Shared with Jev (OpenRouter key in AI › Jev)").foregroundStyle(.secondary) }
                } else if quillKeys.hasKey {
                    LabeledContent("Key") {
                        HStack { Text("Stored in Keychain").foregroundStyle(.secondary); Button("Remove", action: remove).controlSize(.small) }
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("Quill key", text: $key, prompt: Text("Paste an OpenRouter key (sk-or-…)")).onSubmit(save)
                        Button("Save", action: save).controlSize(.small).disabled(!key.trimmingCharacters(in: .whitespaces).hasPrefix("sk-or-"))
                    }
                    Link("Get an OpenRouter key", destination: URL(string: "https://openrouter.ai/keys")!).font(.caption)
                }
                if !keyMessage.isEmpty { Text(keyMessage).font(.caption).foregroundStyle(.orange) }
            }
            Section("What Quill may read") {
                Text("Text after “ask” is always sent. Everything else is off until you turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Selected text, for rewrites and explanations", isOn: $preferences.quillSendsSelection)
                Toggle("Mail messages, for summaries and reply drafts", isOn: $preferences.quillSendsMail)
                Toggle("Calendar and reminders, for scheduled tasks", isOn: $preferences.quillSendsCalendar)
                Toggle("Unread mail list (senders, subjects, previews), for scheduled tasks", isOn: $preferences.quillSendsUnreadMail)
                if DictationEngines.isSupported {
                    Toggle("Dictation transcripts, to fix punctuation and remove fillers", isOn: $preferences.quillSendsDictation)
                }
                InfoCaption("File paths, clipboard history, and audio are never sent.",
                            detail: "Task results stay in Quill Task Results. Only a failed task shows an alert below the notch.")
            }
            Section("Scheduled tasks") {
                QuillTaskSettings(center: tasks)
                Text("For background work that runs when Jevcast is closed, use Settings › Automations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Activity") {
                if log.entries.isEmpty {
                    Text("No Quill requests yet.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Requests") {
                        HStack {
                            Text("\(log.entries.count) · $" + String(format: "%.4f", log.totalCost)).monospacedDigit()
                            Button("View Activity…") { showsActivity = true }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .task { await jevKeys.load(); await quillKeys.load() }
        .sheet(isPresented: $showsActivity) { QuillActivitySheet(log: log) }
    }

    static func details(_ entry: QuillActivityLog.Entry) -> String {
        let sent = "Sent: " + entry.sent.map(\.title).joined(separator: ", ")
        guard entry.succeeded else { return sent + " · failed" }
        let cost = entry.cost.map { " · $" + String(format: "%.5f", $0) } ?? ""
        return sent + " · \(entry.effort.title)" + (entry.fast ? " · Fast" : "") + " · \(entry.inputTokens + entry.outputTokens) tokens" + cost
    }
    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-or-") else { keyMessage = "Quill needs an OpenRouter key that starts with sk-or-."; return }
        do { try quillKeys.save(trimmed); key = ""; keyMessage = "" } catch { keyMessage = error.localizedDescription }
    }
    private func remove() {
        do { try quillKeys.delete(); keyMessage = "" } catch { keyMessage = error.localizedDescription }
    }
}

/// Every logged Quill request, newest first. Entries hold no request or reply text.
private struct QuillActivitySheet: View {
    @ObservedObject var log: QuillActivityLog
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            List(log.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.action).lineLimit(1)
                        Spacer()
                        Text(entry.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                    }
                    Text(QuillSettings.details(entry)).font(.caption).foregroundStyle(entry.succeeded ? Color.secondary : Color.orange)
                }
            }
            Divider()
            HStack {
                Button("Clear Activity", role: .destructive) { log.clear() }.disabled(log.entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 420)
    }
}
