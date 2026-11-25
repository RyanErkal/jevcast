import SwiftUI

/// The composer's From line: the sending address as quiet text with a small chevron, like the
/// other header lines. Its menu picks another account and, for Jevcast's own accounts, inserts
/// the signature by hand.
struct MailComposeFromMenu: View {
    @ObservedObject var model: MailModel
    let draft: MailModel.Draft

    private var current: MailSendingIdentity? {
        model.senders.first { $0.accountID == draft.fromAccountID && $0.address == draft.fromAddress }
    }

    var body: some View {
        Menu {
            ForEach(model.senders) { sender in
                Button { model.selectSender(sender.id) } label: {
                    if sender.id == current?.id { Label(sender.title, systemImage: "checkmark") } else { Text(sender.title) }
                }
            }
            if draft.backend == MailBackend.jevcast.rawValue {
                Divider()
                Button("Insert Signature") { model.insertSignature() }
                    .disabled(model.signature(for: draft).isEmpty)
            }
        } label: {
            Text(current?.title ?? "Select an account").lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(current == nil ? Color.orange : Color.primary)
        .help(current == nil ? "Choose the account to send from" : "Sending account. Set signatures in Settings › Mail.")
        .accessibilityLabel("From")
        .accessibilityValue(current?.title ?? "No account")
    }
}
