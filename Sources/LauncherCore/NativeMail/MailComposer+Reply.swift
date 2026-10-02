import Foundation

/// Replies and forwards built from the original message's headers and text, as Apple Mail does.
public enum MailReplies {
    /// "Re: Lunch", without stacking prefixes such as "Re: Re:".
    public static func replySubject(_ subject: String) -> String {
        prefixed("Re: ", subject, known: ["re:", "aw:", "sv:", "vs:"])
    }
    public static func forwardSubject(_ subject: String) -> String {
        prefixed("Fwd: ", subject, known: ["fwd:", "fw:"])
    }
    private static func prefixed(_ prefix: String, _ subject: String, known: [String]) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return known.contains { trimmed.lowercased().hasPrefix($0) } ? trimmed : prefix + trimmed
    }

    /// Who a reply goes to. Reply-To wins over From. Replying to all adds the original To and Cc,
    /// without your own addresses and without anyone twice. A reply to your own message goes to
    /// its recipients.
    public static func recipients(of original: MIMEMessage, all: Bool, own: Set<String>) -> (to: [MailContact], cc: [MailContact]) {
        func contacts(_ header: String) -> [MailContact] {
            MailAddress.list(original.header(header) ?? "").map { MailContact(name: $0.name, address: $0.address) }.filter { !$0.address.isEmpty }
        }
        let mine = Set(own.map { $0.lowercased() })
        let from = contacts("From")
        let replyTo = contacts("Reply-To")
        var to = replyTo.isEmpty ? from : replyTo
        if to.allSatisfy({ mine.contains($0.address.lowercased()) }) { to = contacts("To") }
        var cc: [MailContact] = []
        if all {
            var seen = Set(to.map { $0.address.lowercased() }).union(mine)
            for contact in contacts("To") + contacts("Cc") where !seen.contains(contact.address.lowercased()) {
                seen.insert(contact.address.lowercased())
                cc.append(contact)
            }
        }
        return (to, cc)
    }

    /// The original's References, then its Message-ID, for threading.
    public static func references(of original: MIMEMessage) -> (inReplyTo: String?, references: [String]) {
        let id = original.header("Message-ID").flatMap(messageIDs)?.first
        var references = messageIDs(original.header("References") ?? "") ?? []
        if references.isEmpty, let parent = original.header("In-Reply-To").flatMap(messageIDs)?.first { references = [parent] }
        if let id { references.append(id) }
        // Long threads keep the first and the most recent references.
        if references.count > 20 { references = [references[0]] + references.suffix(19) }
        return (id, references)
    }

    /// "<a@b> <c@d>" → ["<a@b>", "<c@d>"].
    public static func messageIDs(_ header: String) -> [String]? {
        var found: [String] = []
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            found.append(String(rest[open...close]))
            rest = rest[rest.index(after: close)...]
        }
        return found.isEmpty ? nil : found
    }

    /// Your text, then "On 2 Oct 2026, at 03:01, <sender> wrote:" and the original text quoted
    /// with "> ". Without `quote`, only your text.
    public static func replyBody(_ text: String, original: MIMEMessage, sender: String, date: Date, quote: Bool = true) -> String {
        guard quote else { return text }
        let quoted = lines(original.readableText).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        return text + "\n\n" + replyAttribution(date: date, sender: sender) + "\n\n" + quoted + "\n"
    }

    /// The line above a quote, as Apple Mail writes it: "On 2 Oct 2026, at 03:01, Sam <sam@example.com> wrote:".
    /// The same words go in the plain and the HTML part.
    public static func replyAttribution(date: Date, sender: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy', at 'HH:mm"
        return "On " + formatter.string(from: date) + ", " + sender + " wrote:"
    }

    /// Your text, then the original's headers and text, as a forward in Apple Mail looks.
    public static func forwardBody(_ text: String, original: MIMEMessage, date: Date) -> String {
        var lines = ["", "", "Begin forwarded message:", ""]
        if let from = original.header("From") { lines.append("From: " + from) }
        if let subject = original.header("Subject") { lines.append("Subject: " + subject) }
        lines.append("Date: " + attribution(date))
        if let to = original.header("To") { lines.append("To: " + to) }
        if let cc = original.header("Cc") { lines.append("Cc: " + cc) }
        lines.append("")
        return text + lines.joined(separator: "\n") + "\n" + Self.lines(original.readableText).joined(separator: "\n") + "\n"
    }

    /// Lines of text with any line ending, without trailing blank lines.
    static func lines(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty { result.removeLast() }
        return result
    }

    /// "2 Oct 2026 at 03:01", for a forward's Date line.
    public static func attribution(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
}
