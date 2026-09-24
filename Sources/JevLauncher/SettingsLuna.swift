import SwiftUI
import LauncherCore

/// Luna: the writing model for answers, rewrites, and mail. Every kind of context has its own switch.
struct LunaSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var log: LunaActivityLog
    @ObservedObject var jevKeys: JevKeyCache
    @ObservedObject var lunaKeys: JevKeyCache
    let tasks: LunaTaskCenter
    @State private var key = ""
    @State private var keyMessage = ""

    private var usesJevKey: Bool {
        if case .present(let value) = jevKeys.state, value.hasPrefix("sk-or-"), !lunaKeys.hasKey { return true }
        return false
    }
    private var hasKey: Bool { usesJevKey || lunaKeys.hasKey }

    var body: some View {
        Form {
            Section("Luna") {
                Toggle("Use Luna for answers and writing", isOn: $preferences.lunaEnabled)
                Text("Jev decides what a request means. Luna, GPT-6 Luna through OpenRouter, writes text when a request needs it: “ask …”, rewrites of selected text, and mail summaries and replies. Luna never runs actions.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Effort", selection: $preferences.lunaEffort) {
                    ForEach(LunaEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Fast answers in seconds. High and Max think longer and cost more.").font(.caption).foregroundStyle(.secondary)
            }
            Section("OpenRouter key") {
                if usesJevKey {
                    LabeledContent("Key") { Text("Uses your Jev OpenRouter key").foregroundStyle(.secondary) }
                } else if lunaKeys.hasKey {
                    LabeledContent("Key") {
                        HStack { Text("Stored in Keychain").foregroundStyle(.secondary); Button("Remove", action: remove).controlSize(.small) }
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("Luna key", text: $key, prompt: Text("Paste an OpenRouter key (sk-or-…)")).onSubmit(save)
                        Button("Save", action: save).controlSize(.small).disabled(!key.trimmingCharacters(in: .whitespaces).hasPrefix("sk-or-"))
                    }
                    Link("Get an OpenRouter key", destination: URL(string: "https://openrouter.ai/keys")!).font(.caption)
                }
                if !keyMessage.isEmpty { Text(keyMessage).font(.caption).foregroundStyle(.orange) }
            }
            Section("What Luna may read") {
                Text("What you type after “ask” is always sent when Luna is on. Everything else is off until you turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Selected text, for rewrites and explanations", isOn: $preferences.lunaSendsSelection)
                Toggle("Mail messages, for summaries and reply drafts", isOn: $preferences.lunaSendsMail)
                Toggle("Calendar and reminders, for scheduled tasks", isOn: $preferences.lunaSendsCalendar)
                Toggle("Unread mail list (senders, subjects, previews), for scheduled tasks", isOn: $preferences.lunaSendsUnreadMail)
                if DictationEngines.isSupported {
                    Toggle("Dictation transcripts, to fix punctuation and remove fillers", isOn: $preferences.lunaSendsDictation)
                }
                Text("Task results show in notifications, which can appear on the lock screen. Change that in System Settings › Notifications.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("File paths, clipboard history, and audio are never sent.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Scheduled tasks") {
                LunaTaskSettings(center: tasks)
            }
            Section("Activity") {
                if log.entries.isEmpty {
                    Text("No Luna requests yet.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Requests") { Text("\(log.entries.count) · $" + String(format: "%.4f", log.totalCost)) }
                    ForEach(log.entries.prefix(12)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.action).lineLimit(1)
                                Spacer()
                                Text(entry.date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                            }
                            Text(details(entry)).font(.caption).foregroundStyle(entry.succeeded ? Color.secondary : Color.orange)
                        }
                    }
                    Button("Clear Activity", role: .destructive) { log.clear() }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .task { await jevKeys.load(); await lunaKeys.load() }
    }

    private func details(_ entry: LunaActivityLog.Entry) -> String {
        let sent = "Sent: " + entry.sent.map(\.title).joined(separator: ", ")
        guard entry.succeeded else { return sent + " · failed" }
        let cost = entry.cost.map { " · $" + String(format: "%.5f", $0) } ?? ""
        return sent + " · \(entry.effort.title) · \(entry.inputTokens + entry.outputTokens) tokens" + cost
    }
    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-or-") else { keyMessage = "Luna needs an OpenRouter key that starts with sk-or-."; return }
        do { try lunaKeys.save(trimmed); key = ""; keyMessage = "" } catch { keyMessage = error.localizedDescription }
    }
    private func remove() {
        do { try lunaKeys.delete(); keyMessage = "" } catch { keyMessage = error.localizedDescription }
    }
}
