import AppKit
import LauncherCore
import SwiftUI

/// Invented composition state only. No store, account, credential, or send path is used.
@MainActor
enum MailSnapshots {
    static func composer() -> some View {
        let model = fixture()
        model.draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                      mode: .new, to: "sam@example.com", subject: "Friday's Plan", body: "Hi Sam,\n\nFriday at 10 works for me. I have attached the agenda.\n\nAlex")
        model.draft?.attachments = [.init(filename: "Agenda.pdf", mimeType: "application/pdf", data: Data(repeating: 0, count: 2048))]
        return ComposeView(model: model)
    }

    /// A reply to an invented HTML newsletter, with its quote below the text, as it is sent.
    static func reply() -> some View {
        let model = fixture()
        let raw = """
        From: Bodhi <bodhi@example.com>\r
        To: alex@example.com\r
        Subject: Stop Letting Leads Die\r
        Message-ID: <demo-1@example.com>\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><head><style>.card{background:#f0f0f0;border-radius:12px;padding:20px;font-family:Helvetica}h1{font-size:28px}</style></head>
        <body><div class="card"><h1>Stop Letting Leads Die</h1><p>Someone leaves your website without calling? Keep marketing to them.</p>
        <p>This is why retargeting works for home service businesses.</p></div></body></html>\r
        """
        let message = MIMEMessage.parse(Data(raw.utf8))!
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 3, minute: 1)) ?? Date()
        let original = MailSummary(rowID: 1, mailbox: 1, subject: "Stop Letting Leads Die", senderName: "Bodhi", senderAddress: "bodhi@example.com",
                                   snippet: "", date: date, read: true, flagged: false, conversation: 0)
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                    mode: .reply(all: false), subject: "Re: Stop Letting Leads Die", body: "Thanks Bodhi, this is useful.",
                                    original: original, source: .init(rowID: 1, message: message, html: message.html))
        draft.ownAddresses = ["alex@example.com"]
        draft.fillRecipients()
        model.draft = draft
        return ComposeView(model: model)
    }

    static func outbox() -> some View {
        let model = fixture()
        var draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com",
                                    mode: .new, to: "sam@example.com", subject: "Friday's Plan", body: "Friday at 10 works.")
        draft.uncertainSend = true
        model.deliveries = [.init(id: draft.id, draft: draft, subject: draft.subject, recipient: draft.to, date: Date(), state: .uncertain,
                                 note: "The server may have accepted this message. Check Sent before resending.")]
        return MailDeliveryView(model: model)
    }

    private static func fixture() -> MailModel {
        let model = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false }, statusProvider: { .noMail },
                              setRead: { _, _, _, _ in throw CancellationError() }, sendDraft: { _, _ in throw CancellationError() }, draftStore: nil)
        model.senders = [.init(accountID: "demo", address: "alex@example.com", name: "Alex Morgan", signature: "Alex Morgan")]
        return model
    }
}
