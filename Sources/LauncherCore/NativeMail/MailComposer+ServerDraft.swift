import Foundation

extension MailComposer {
    /// Renders a message for an IMAP Drafts mailbox. Drafts deliberately retain Bcc so that a
    /// draft opened on another device can be edited without losing recipients. `render(_:)`
    /// remains the sent-message renderer and never writes Bcc.
    ///
    /// Raw recipient fields are accepted for drafts because a person can save an incomplete
    /// address while typing. They are cleaned before entering a header, so a partial value can
    /// never inject a second header or a new MIME part.
    public static func renderServerDraft(_ message: OutgoingMessage, toHeader: String? = nil,
                                         ccHeader: String? = nil, bccHeader: String? = nil) -> Data {
        var headers: [(String, String)] = [
            ("Date", rfc5322Date(message.date)),
            ("From", addressList([message.from]))
        ]
        appendRecipient("To", raw: toHeader, contacts: message.to, to: &headers)
        appendRecipient("Cc", raw: ccHeader, contacts: message.cc, to: &headers)
        appendRecipient("Bcc", raw: bccHeader, contacts: message.bcc, to: &headers)
        headers.append(("Subject", encodedText(message.subject)))
        headers.append(("Message-ID", clean(message.messageID)))
        if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty {
            headers.append(("In-Reply-To", clean(inReplyTo)))
        }
        if !message.references.isEmpty {
            headers.append(("References", message.references.map(clean).joined(separator: " ")))
        }
        headers.append(("MIME-Version", "1.0"))

        var out = ""
        for (name, value) in headers { out += fold("\(name): \(value)") + "\r\n" }
        var data = Data(out.utf8)
        data.append(bodyPart(message))
        return data
    }

    private static func appendRecipient(_ name: String, raw: String?, contacts: [MailContact],
                                        to headers: inout [(String, String)]) {
        let cleaned = raw.map(clean).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let value = cleaned.flatMap { $0.isEmpty ? nil : $0 } ?? addressList(contacts)
        if !value.isEmpty { headers.append((name, value)) }
    }
}
