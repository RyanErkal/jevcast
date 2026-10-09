import SwiftUI

/// Send Later editor for an already captured draft. The draft and its source remain unchanged if
/// persistence fails, so the composer can keep showing the original text and attachments.
struct MailScheduleEditor: View {
    let draft: MailModel.Draft
    let account: MailAccountIdentity
    @ObservedObject var center: MailScheduleCenter
    let existingID: UUID?
    let onScheduled: (MailScheduleEntry) -> Void
    /// Called only by Return to Drafts after an existing schedule is durably cancelled.
    let onReturnToDrafts: (MailScheduleEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var sentCheckConfirmed = false
    @State private var problem: String?

    init(draft: MailModel.Draft, account: MailAccountIdentity, center: MailScheduleCenter,
         existingID: UUID? = nil, initialDate: Date? = nil,
         onScheduled: @escaping (MailScheduleEntry) -> Void = { _ in },
         onReturnToDrafts: @escaping (MailScheduleEntry) -> Void = { _ in }) {
        self.draft = draft
        self.account = account
        self.center = center
        self.existingID = existingID
        self.onScheduled = onScheduled
        self.onReturnToDrafts = onReturnToDrafts
        _date = State(initialValue: initialDate ?? Date().addingTimeInterval(3600))
    }

    private var requiresSentCheck: Bool {
        if draft.uncertainSend { return true }
        guard let existingID else { return false }
        return center.entries.first(where: { $0.id == existingID })?.requiresSentCheck == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existingID == nil ? "Send Later" : "Edit Scheduled Message").font(.headline)
            ScrollView {
                MailDraftReadOnlyReview(draft: draft)
                DatePicker("Send at", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                if requiresSentCheck {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("This dispatch may already have reached the mail server.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button(sentCheckConfirmed ? "Sent checked" : "I checked Sent and it is not there") {
                            sentCheckConfirmed = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(sentCheckConfirmed)
                    }
                    .font(.caption)
                }
                Text("Runs only while Jevcast is open. A missed or interrupted send needs review.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                if existingID != nil {
                    Button("Return to Drafts") { returnToDrafts() }
                }
                Spacer()
                Button(existingID == nil ? "Schedule" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(requiresSentCheck && !sentCheckConfirmed)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 430, maxHeight: 640)
    }

    private func save() {
        do {
            let item: MailScheduleEntry
            if let existingID {
                item = try center.edit(existingID, draft: draft, account: account, at: date,
                                       confirmSentCheck: sentCheckConfirmed)
            } else {
                item = try center.schedule(draft, account: account, at: date,
                                           confirmSentCheck: sentCheckConfirmed)
            }
            onScheduled(item); dismiss()
        } catch { problem = error.localizedDescription }
    }

    private func returnToDrafts() {
        guard let existingID,
              let item = center.entries.first(where: { $0.id == existingID }) else { return }
        do {
            try center.cancel(existingID)
            onReturnToDrafts(item)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}

/// Read-only review of every value that Send Later persists. It stays inside the launcher
/// popover, so reviewing a message never opens a composer or another window.
struct MailDraftReadOnlyReview: View {
    let draft: MailModel.Draft

    private var reviewBody: String {
        draft.body.isEmpty ? (draft.serverDraftHTMLBody ?? "") : draft.body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("From", value: draft.fromAddress ?? "")
            field("To", value: draft.to)
            field("Cc", value: draft.cc)
            field("Bcc", value: draft.bcc)
            field("Subject", value: draft.subject)
            Divider()
            Text("Message").font(.caption).foregroundStyle(.secondary)
            Text(reviewBody.isEmpty ? "(No body)" : reviewBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if draft.richText != nil {
                Text("Rich-text formatting is preserved when this message is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !draft.attachments.isEmpty {
                Divider()
                Text("Attachments").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(draft.attachments.enumerated()), id: \.offset) { _, attachment in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "paperclip")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.filename.isEmpty ? "Unnamed attachment" : attachment.filename)
                            Text("\(attachment.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func field(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "(None)" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

struct MailScheduleButton: View {
    let draft: MailModel.Draft
    let account: MailAccountIdentity
    @ObservedObject var center: MailScheduleCenter
    let onScheduled: (MailScheduleEntry) -> Void
    @State private var showingEditor = false

    init(draft: MailModel.Draft, account: MailAccountIdentity, center: MailScheduleCenter,
         onScheduled: @escaping (MailScheduleEntry) -> Void = { _ in }) {
        self.draft = draft
        self.account = account
        self.center = center
        self.onScheduled = onScheduled
    }

    var body: some View {
        Button { showingEditor = true } label: { Label("Send Later…", systemImage: "clock.arrow.circlepath") }
            .popover(isPresented: $showingEditor) {
                MailScheduleEditor(draft: draft, account: account, center: center, onScheduled: onScheduled)
            }
            .help("Schedule this complete draft")
    }
}

struct MailScheduleList: View {
    @ObservedObject var center: MailScheduleCenter
    let onReview: (MailScheduleEntry) -> Void
    /// Called after a durable cancel, with the retained snapshot so the root can reopen
    /// `entry.draft` in the normal Drafts surface.
    let onReturnToDrafts: (MailScheduleEntry) -> Void
    @State private var editing: MailScheduleEntry?
    @State private var problem: String?

    init(center: MailScheduleCenter, onReview: @escaping (MailScheduleEntry) -> Void = { _ in },
         onReturnToDrafts: @escaping (MailScheduleEntry) -> Void = { _ in }) {
        self.center = center
        self.onReview = onReview
        self.onReturnToDrafts = onReturnToDrafts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scheduled on this Mac").font(.headline)
            if center.visible.isEmpty {
                Text("No scheduled messages").foregroundStyle(.secondary)
            } else {
                ForEach(center.visible) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(item.state)).foregroundStyle(color(item.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.draft.subject.isEmpty ? "No subject" : item.draft.subject).lineLimit(1)
                            Text(item.draft.to.isEmpty ? "No recipient" : item.draft.to)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(label(item)).font(.caption).foregroundStyle(.secondary)
                            if let note = item.note { Text(note).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        controls(item)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .popover(item: $editing) { item in
            MailScheduleEditor(draft: item.draft, account: item.account, center: center,
                                existingID: item.id, initialDate: item.scheduledAt,
                                onReturnToDrafts: onReturnToDrafts)
        }
    }

    @ViewBuilder private func controls(_ item: MailScheduleEntry) -> some View {
        switch item.state {
        case .scheduled, .needsReview:
            Button(item.state == .needsReview ? "Review" : "Edit") {
                if item.state == .needsReview { onReview(item) }
                editing = item
            }.controlSize(.small)
            Button("Cancel", role: .destructive) {
                do {
                    try center.cancel(item.id)
                    onReturnToDrafts(item)
                }
                catch { problem = error.localizedDescription }
            }.controlSize(.small)
        case .dispatching:
            Text("Sending…").font(.caption)
        case .submitted:
            Text("Submitted").font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            EmptyView()
        }
    }

    private func label(_ item: MailScheduleEntry) -> String {
        switch item.state {
        case .scheduled: return "Sends " + item.scheduledAt.formatted(date: .abbreviated, time: .shortened)
        case .dispatching: return "Sending now"
        case .submitted: return item.scheduledAt.formatted(date: .abbreviated, time: .shortened)
        case .needsReview: return "Needs review"
        case .cancelled: return "Cancelled"
        }
    }

    private func symbol(_ state: MailScheduleState) -> String {
        switch state {
        case .scheduled: return "clock"
        case .dispatching: return "arrow.up.circle"
        case .submitted: return "checkmark.circle"
        case .needsReview: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(_ state: MailScheduleState) -> Color {
        switch state {
        case .needsReview: return .orange
        case .submitted: return .green
        case .cancelled: return .secondary
        default: return .secondary
        }
    }
}
