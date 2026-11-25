import AppKit
import LauncherCore

/// Automatic signatures. A new message, reply, or forward starts with the sending account's
/// signature below a blank line; for a reply that is above the original, which goes below your
/// text. Changing From swaps the signature while it is unchanged. A draft opened again, restored,
/// or from a server never gets a second one. Settings: Mail Settings › Aliases & Signatures.
enum MailSignatures {
    /// On unless turned off.
    static let automaticKey = "mailAutomaticSignatures"

    static func isAutomatic(_ defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: automaticKey) as? Bool ?? true
    }
}

extension MailModel {
    /// Puts the sending account's signature at the end of a draft Jevcast started, or swaps the
    /// one it put there for the account now chosen. A signature you changed stays as you left it.
    /// Safe to call again: the same account changes nothing.
    func applyAutomaticSignature(_ draft: inout Draft) {
        guard draft.signsAutomatically == true, MailSignatures.isAutomatic(mailDefaults) else { return }
        guard let sender = senders.first(where: { $0.accountID == draft.fromAccountID
            && $0.address.caseInsensitiveCompare(draft.fromAddress ?? "") == .orderedSame }) else { return }
        let new = MailSignatureText.clean(sender.signature)
        let old = draft.automaticSignature
        guard new != (old ?? "") else { return }
        let typed: String
        if let old {
            guard let part = MailSignatureText.typedPart(of: draft.body, signature: old) else {
                // You changed it: it is yours now.
                draft.signsAutomatically = false
                return
            }
            typed = part
        } else {
            typed = draft.body
        }
        replaceSignature(in: &draft, typedLength: (typed as NSString).length, signature: new)
        draft.automaticSignature = new.isEmpty ? nil : new
    }

    /// Replaces everything after your text, keeping its styles when the draft has rich text.
    func replaceSignature(in draft: inout Draft, typedLength: Int, signature: String) {
        let tail = signature.isEmpty ? "" : MailSignatureText.separator + signature
        guard let rich = draft.richText else {
            draft.body = String((draft.body as NSString).substring(to: typedLength)) + tail
            return
        }
        let text = NSMutableAttributedString(attributedString: MailRichText.attributed(rich, plain: draft.body))
        let start = min(typedLength, text.length)
        text.replaceCharacters(in: NSRange(location: start, length: text.length - start),
                               with: NSAttributedString(string: tail, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]))
        draft.body = text.string
        draft.richText = try? text.data(from: NSRange(location: 0, length: text.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// The signature of the account the draft sends from, or "" when it has none.
    func signature(for draft: Draft) -> String {
        senders.first { $0.accountID == draft.fromAccountID && $0.address == draft.fromAddress }
            .map { MailSignatureText.clean($0.signature) } ?? ""
    }
}
