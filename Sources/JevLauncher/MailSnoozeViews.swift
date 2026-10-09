import SwiftUI
import LauncherCore

/// A compact editor that can be embedded in the launcher panel. It does not create a mail or
/// compose window. The caller decides what to do with a ready item after the local snooze is
/// consumed.
struct MailSnoozeEditor: View {
    let entry: MailSnoozeEntry
    @ObservedObject var center: MailSnoozeCenter
    let onDone: () -> Void
    private let saveDate: (Date) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var problem: String?

    init(entry: MailSnoozeEntry, center: MailSnoozeCenter, onDone: @escaping () -> Void = {}) {
        self.entry = entry
        self.center = center
        self.onDone = onDone
        saveDate = { try center.reschedule(entry.identity, until: $0) }
        _date = State(initialValue: entry.scheduledAt)
    }

    init(message: MailSummary, account: MailAccountIdentity, messageID: String?, center: MailSnoozeCenter,
         initialDate: Date, onDone: @escaping () -> Void = {}) {
        let identity = MailMessageIdentity(account: account, messageKey: message.messageKey, messageID: messageID)
        self.entry = MailSnoozeEntry(identity: identity, account: account, summary: message, createdAt: Date(),
                                     scheduledAt: initialDate, state: .scheduled, note: nil)
        self.center = center
        self.onDone = onDone
        saveDate = { date in _ = try center.snooze(message: message, account: account, messageID: messageID, until: date) }
        _date = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snooze on this Mac").font(.headline)
            Text(entry.summary.subject.isEmpty ? "No subject" : entry.summary.subject).lineLimit(2)
            DatePicker("Return at", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    do {
                        try saveDate(date)
                        onDone(); dismiss()
                    } catch { problem = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 300)
    }
}

struct MailSnoozeButton: View {
    let message: MailSummary
    let account: MailAccountIdentity
    let messageID: String?
    @ObservedObject var center: MailSnoozeCenter
    let defaultDate: Date
    let onSnoozed: (MailSnoozeEntry) -> Void
    @State private var showingEditor = false

    init(message: MailSummary, account: MailAccountIdentity, messageID: String? = nil,
         center: MailSnoozeCenter, defaultDate: Date? = nil,
         onSnoozed: @escaping (MailSnoozeEntry) -> Void = { _ in }) {
        self.message = message
        self.account = account
        self.messageID = messageID
        self.center = center
        self.defaultDate = defaultDate ?? Date().addingTimeInterval(3600)
        self.onSnoozed = onSnoozed
    }

    var body: some View {
        Button { showingEditor = true } label: { Label("Snooze…", systemImage: "clock") }
            .popover(isPresented: $showingEditor) {
                MailSnoozeEditor(message: message, account: account, messageID: messageID,
                                 center: center, initialDate: defaultDate,
                                 onDone: { if let item = center.entries.first(where: { $0.identity.accountID == account.accountID && $0.identity.messageKey == message.messageKey && $0.state == .scheduled }) { onSnoozed(item) } })
            }
            .help("Snooze this message on this Mac")
    }
}

struct MailSnoozeList: View {
    @ObservedObject var center: MailSnoozeCenter
    let onReady: (MailSnoozeEntry) -> Void
    @State private var editing: MailSnoozeEntry?
    @State private var problem: String?

    init(center: MailSnoozeCenter, onReady: @escaping (MailSnoozeEntry) -> Void = { _ in }) {
        self.center = center
        self.onReady = onReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snoozed on this Mac").font(.headline)
            if center.entries.isEmpty {
                Text("No snoozed messages").foregroundStyle(.secondary)
            } else {
                ForEach(center.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(entry.state)).foregroundStyle(color(entry.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.summary.subject.isEmpty ? "No subject" : entry.summary.subject).lineLimit(1)
                            Text(entry.summary.sender).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(label(entry)).font(.caption).foregroundStyle(.secondary)
                            if let note = entry.note { Text(note).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        controls(entry)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .popover(item: $editing) { item in
            MailSnoozeEditor(entry: item, center: center)
        }
    }

    @ViewBuilder private func controls(_ entry: MailSnoozeEntry) -> some View {
        if entry.state == .ready {
            Button("Return") {
                do { onReady(try center.consumeReady(entry.identity)) }
                catch { problem = error.localizedDescription }
            }.controlSize(.small)
        } else {
            Button("Edit") { editing = entry }.controlSize(.small)
            Button("Cancel", role: .destructive) {
                do { try center.cancel(entry.identity) }
                catch { problem = error.localizedDescription }
            }.controlSize(.small)
        }
    }

    private func label(_ entry: MailSnoozeEntry) -> String {
        switch entry.state {
        case .scheduled: return "Returns " + entry.scheduledAt.formatted(date: .abbreviated, time: .shortened)
        case .ready: return "Ready to return"
        case .needsReview: return "Needs review"
        }
    }

    private func symbol(_ state: MailSnoozeState) -> String {
        switch state { case .scheduled: return "clock"; case .ready: return "arrow.uturn.left"; case .needsReview: return "exclamationmark.triangle" }
    }

    private func color(_ state: MailSnoozeState) -> Color {
        state == .needsReview ? .orange : .secondary
    }
}
