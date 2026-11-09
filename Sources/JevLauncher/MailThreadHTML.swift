import Foundation
import LauncherCore

/// Builds one script-free reader document. Each sender's CSS stays inside its own message.
///
/// The subject shows once, above the replies. Each reply has one header line: who and when. In a
/// long conversation the older replies that you have read start closed, as one line with the start
/// of their text; a click opens one. The page follows the Mac's light or dark appearance, and an
/// HTML message keeps the white page its sender designed for.
enum MailThreadHTML {
    struct Entry {
        let message: MailSummary
        let body: MailModel.Body?
    }

    /// Replies beyond this many start closed when they are read.
    static let openReplies = 2

    static let style = "<style>:root{color-scheme:light dark}"
        + "body{margin:0!important;background:#fff;color:#202124}"
        + ".jev-title{font:600 16px -apple-system,sans-serif!important;padding:14px 18px 6px}"
        + ".jev-message{border-bottom:1px solid rgba(128,128,128,.28)}"
        + ".jev-message>summary{list-style:none;cursor:default;padding:10px 18px 8px;outline:none}"
        + ".jev-message>summary::-webkit-details-marker{display:none}"
        + ".jev-row{display:flex;gap:8px;align-items:baseline;font:13px -apple-system,sans-serif!important}"
        + ".jev-from{font-weight:600;color:inherit!important;text-decoration:none;white-space:nowrap}"
        + ".jev-address,.jev-date,.jev-snippet,.jev-meta{color:#6b6b6b;font:12px -apple-system,sans-serif!important}"
        + ".jev-address{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}"
        + ".jev-snippet{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;display:none}"
        + ".jev-date{margin-left:auto;white-space:nowrap}"
        + ".jev-message:not([open])>summary .jev-address{display:none}"
        + ".jev-message:not([open])>summary .jev-snippet{display:block}"
        + ".jev-meta{padding:0 18px 4px;display:block}"
        + ".jev-body{padding:6px 18px 18px}"
        + ".jev-html{background:#fff;color:#202124}"
        + ".jev-plain{font:14px -apple-system,sans-serif}"
        + ".jev-body blockquote[type=cite],.jev-body .gmail_quote,.jev-body .yahoo_quoted{display:none!important}"
        + ".jev-message:has(.jev-quotes:checked) .jev-body blockquote[type=cite],"
        + ".jev-message:has(.jev-quotes:checked) .jev-body .gmail_quote,"
        + ".jev-message:has(.jev-quotes:checked) .jev-body .yahoo_quoted{display:block!important}"
        + "@media (prefers-color-scheme:dark){"
        + "body{background:#1c1c1e;color:#e8e8ea}"
        + ".jev-address,.jev-date,.jev-snippet,.jev-meta{color:#a0a0a5}"
        + ".jev-html{border-radius:8px;padding:12px}"
        + ".jev-plain a{color:#6cb4ff}}"
        + "</style>"

    static func render(_ entries: [Entry], prefersPlain: Bool) -> String {
        guard let first = entries.first else { return style }
        let subject = first.message.subject.isEmpty ? "No subject" : first.message.subject
        let collapses = entries.count > openReplies + 1
        let title = "<div class=\"jev-title\">" + MailHTML.escape(subject) + "</div>"
        return style + title + entries.enumerated().map { index, entry in
            let message = entry.message
            let id = String(message.rowID)
            // An unread reply, or one whose text is missing, always starts open.
            let open = !collapses || index < openReplies || !message.read || entry.body == nil
            var summary = "<summary><div class=\"jev-row\">"
            summary += "<a class=\"jev-from\" href=\"jevcast-message://select/" + id + "\">" + MailHTML.escape(message.sender) + "</a>"
            if !message.senderName.isEmpty { summary += "<span class=\"jev-address\">&lt;" + MailHTML.escape(message.senderAddress) + "&gt;</span>" }
            summary += "<span class=\"jev-snippet\">" + MailHTML.escape(MailConversationSummaryRow.preview(message.snippet)) + "</span>"
            summary += "<span class=\"jev-date\">" + MailHTML.escape(message.date.formatted(date: .abbreviated, time: .shortened)) + "</span>"
            summary += "</div></summary>"
            var facts = ""
            if let detail = entry.body?.message {
                if let to = detail.header("To") { facts += "<span class=\"jev-meta\">To: " + MailHTML.escape(to) + "</span>" }
                if !detail.attachments.isEmpty {
                    facts += "<span class=\"jev-meta\">Attachments: " + MailHTML.escape(detail.attachments.map(\.name).joined(separator: ", ")) + "</span>"
                }
            }
            let content: String
            var quotes = ""
            if let body = entry.body {
                if !prefersPlain, let html = body.html {
                    content = "<div class=\"jev-html\">" + MailHTML.threadFragment(html, className: "jev-body-" + id) + "</div>"
                    if html.range(of: #"(?is)blockquote\b[^>]*type\s*=\s*["']?cite|gmail_quote|yahoo_quoted"#, options: .regularExpression) != nil {
                        quotes = "<label class=\"jev-meta\"><input class=\"jev-quotes\" type=\"checkbox\"> Show quoted text</label>"
                    }
                } else { content = "<div class=\"jev-plain\">" + MailHTML.plain(body.message.readableText) + "</div>" }
            } else { content = "<p class=\"jev-plain\">This message has not downloaded yet.</p>" }
            return "<details class=\"jev-message\"" + (open ? " open" : "") + ">" + summary + facts + quotes
                + "<div class=\"jev-body\">" + content + "</div></details>"
        }.joined()
    }
}
