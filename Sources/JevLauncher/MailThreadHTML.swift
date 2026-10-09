import Foundation
import LauncherCore

/// Builds one script-free reader document. Each sender's CSS stays inside its own message.
enum MailThreadHTML {
    struct Entry {
        let message: MailSummary
        let body: MailModel.Body?
    }

    static func render(_ entries: [Entry], prefersPlain: Bool) -> String {
        let style = "<style>body{margin:0!important;background:white;color:#202124}"
            + ".jev-message{padding:18px;border-bottom:1px solid #ddd}"
            + ".jev-header{font:13px -apple-system,sans-serif!important;margin-bottom:16px}"
            + ".jev-header a{color:#555}.jev-subject{font-weight:600;margin-bottom:6px}"
            + ".jev-meta{color:#666;font-size:12px;margin-top:5px}"
            + ".jev-body blockquote[type=cite],.jev-body .gmail_quote,.jev-body .yahoo_quoted{display:none!important}"
            + ".jev-message:has(.jev-quotes:checked) .jev-body blockquote[type=cite],"
            + ".jev-message:has(.jev-quotes:checked) .jev-body .gmail_quote,"
            + ".jev-message:has(.jev-quotes:checked) .jev-body .yahoo_quoted{display:block!important}"
            + "</style>"
        return style + entries.map { entry in
            let message = entry.message
            let id = String(message.rowID)
            var header = "<div class=\"jev-header\"><div class=\"jev-subject\">" + MailHTML.escape(message.subject.isEmpty ? "No subject" : message.subject) + "</div>"
            header += "<a href=\"jevcast-message://select/" + id + "\"><b>" + MailHTML.escape(message.sender) + "</b></a> &lt;" + MailHTML.escape(message.senderAddress) + "&gt;"
            header += "<div class=\"jev-meta\">" + MailHTML.escape(message.date.formatted(date: .abbreviated, time: .shortened))
            header += "</div>"
            if let detail = entry.body?.message {
                if let to = detail.header("To") { header += "<div class=\"jev-meta\">To: " + MailHTML.escape(to) + "</div>" }
                if !detail.attachments.isEmpty {
                    header += "<div class=\"jev-meta\">Attachments: " + MailHTML.escape(detail.attachments.map(\.name).joined(separator: ", ")) + "</div>"
                }
            }
            header += "</div>"
            let content: String
            var quotes = ""
            if let body = entry.body {
                if !prefersPlain, let html = body.html {
                    content = MailHTML.threadFragment(html, className: "jev-body-" + id)
                    if html.range(of: #"(?is)blockquote\b[^>]*type\s*=\s*["']?cite|gmail_quote|yahoo_quoted"#, options: .regularExpression) != nil {
                        quotes = "<label class=\"jev-meta\"><input class=\"jev-quotes\" type=\"checkbox\"> Show quoted text</label>"
                    }
                } else { content = MailHTML.plain(body.message.readableText) }
            } else { content = "<p>This message has not downloaded yet.</p>" }
            return "<section class=\"jev-message\">" + header + quotes + "<div class=\"jev-body\">" + content + "</div></section>"
        }.joined()
    }
}
