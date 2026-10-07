import SwiftUI

/// Outbox in the panel, in place of the message list: sends waiting for Undo, sends that did not
/// go or may have gone, and recent send history.
struct MailDeliveryView: View {
    @ObservedObject var model: MailModel
    @State private var resend: MailDelivery?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Messages recovered after restart stay here until you send them. A message marked Uncertain may already be sent.")
                .font(.caption).foregroundStyle(.secondary)
            MailServerDraftCleanupView(model: model)
            if model.deliveries.isEmpty { Text("No send history").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
            else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.deliveries.reversed()) { item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.subject.isEmpty ? "No subject" : item.subject).fontWeight(.medium)
                                    Text(item.recipient).font(.caption).foregroundStyle(.secondary)
                                    Text(title(item.state) + " · " + item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                    if let note = item.note { Text(note).font(.caption).foregroundStyle(.orange) }
                                }
                                Spacer()
                                if item.state == .sentCopyPending {
                                    Button(model.repairingSentCopies.contains(item.id) ? "Saving…" : "Save Sent Copy") { model.repairSentCopy(item) }
                                        .controlSize(.small).disabled(model.repairingSentCopies.contains(item.id))
                                } else if item.state == .uncertain {
                                    Button("Allow Resend…") { resend = item }.controlSize(.small)
                                } else if item.draft != nil && item.state == .failed {
                                    Button("Open Draft") { model.restoreDelivery(item) }.controlSize(.small)
                                } else if item.state == .queued, model.pendingSend?.id == item.id {
                                    Button("Undo") { model.undoSend() }.controlSize(.small)
                                }
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("This message may already be sent", isPresented: Binding(get: { resend != nil }, set: { if !$0 { resend = nil } })) {
            if let resend { Button("I Checked Sent. It Was Not Sent") { model.restoreDelivery(resend, allowResend: true); self.resend = nil } }
            Button("Cancel", role: .cancel) { resend = nil }
        } message: { Text("Check your account's Sent folder first. Allow Resend opens the draft. It does not send the message.") }
    }
    private func title(_ state: MailDelivery.State) -> String {
        switch state {
        case .queued: return "Waiting for Undo"
        case .sending: return "Sending"
        case .sent: return "Sent"
        case .sentCopyPending: return "Sent · Copy pending"
        case .appleMailQueued: return "Queued in Apple Mail"
        case .failed: return "Not sent"
        case .uncertain: return "Uncertain"
        case .undone: return "Undone"
        }
    }
}
