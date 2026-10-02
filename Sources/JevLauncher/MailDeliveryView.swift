import SwiftUI

struct MailDeliveryView: View {
    @ObservedObject var model: MailModel
    @Environment(\.dismiss) private var dismiss
    @State private var resend: MailDelivery?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Outbox").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Messages recovered after restart stay here until you send them. A message marked Uncertain may already be sent.")
                .font(.caption).foregroundStyle(.secondary)
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
                                if item.state == .uncertain {
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
                }.frame(maxHeight: 330)
            }
        }.padding(20).frame(width: 540)
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
        case .failed: return "Not sent"
        case .uncertain: return "Uncertain"
        case .undone: return "Undone"
        }
    }
}
