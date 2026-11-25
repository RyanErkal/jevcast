import Foundation
import LauncherCore

/// Builds one script-free reader document. Each sender's CSS stays inside its own message.
///
/// The reader's header above shows the subject, so the document starts with the replies. Each
/// reply has one header line: the sender's initials, who, and a short date. In a long conversation
/// the older replies that you have read start closed, as one line with the start of their text; a
/// click opens one. The page sits on the reader's own surface and follows the Mac's light or dark
/// appearance; an HTML message that brings its own colours shows on a light card.
enum MailThreadHTML {
    struct Entry {
        let message: MailSummary
        let body: MailModel.Body?
    }

    /// Replies beyond this many start closed when they are read.
    static let openReplies = 2

    /// The prefix of a sender link and of its reply's anchor when no other is given.
    static let defaultPick = "jev-pick-"

    /// A new prefix for each conversation shown. A sender cannot guess it, so a link in a message
    /// cannot mark or select another reply.
    static func newPick() -> String { "jev-" + UUID().uuidString.prefix(8).lowercased() + "-" }

    static let style = "<style>:root{color-scheme:light dark}"
        + "html,body{background:transparent!important}"
        + "body{margin:0!important;padding:2px 0 18px;color:#1d1d1f}"
        + ".jev-message{border-bottom:1px solid rgba(128,128,128,.22)}"
        + ".jev-message>summary{list-style:none;cursor:default;padding:10px 18px 8px}"
        + ".jev-message>summary::-webkit-details-marker{display:none}"
        // A click shows no ring; Tab inside the page does, so you can see what Return opens.
        + "summary:focus:not(:focus-visible){outline:none}"
        + "summary:focus-visible{outline:2px solid #0a84ff;outline:2px solid -apple-system-control-accent;outline-offset:2px}"
        // The reply the toolbar acts on: the one you clicked. Until you click, `mark` names it.
        + ".jev-message:target" + markShadow
        + ".jev-row{display:flex;gap:8px;align-items:center;font:13.5px -apple-system,sans-serif!important}"
        + ".jev-avatar{flex:none;width:24px;height:24px;border-radius:50%;color:#fff;text-align:center;"
        + "font:600 9.5px/24px -apple-system,sans-serif!important;background-image:linear-gradient(rgba(255,255,255,.24),rgba(255,255,255,0))}"
        + ".jev-from{font-weight:600;color:inherit!important;text-decoration:none;white-space:nowrap}"
        + ".jev-address,.jev-date,.jev-snippet,.jev-meta{color:#6b6b6b;font:12px -apple-system,sans-serif!important}"
        + ".jev-address{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}"
        + ".jev-snippet{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;display:none}"
        + ".jev-date{margin-left:auto;white-space:nowrap;padding-left:8px}"
        + ".jev-message:not([open])>summary .jev-address{display:none}"
        + ".jev-message:not([open])>summary .jev-snippet{display:block}"
        + ".jev-facts{display:flex;flex-wrap:wrap;gap:2px 16px;padding:0 18px 2px 50px}"
        + ".jev-body{padding:6px 18px 14px 50px}"
        + ".jev-html{background:#fff;color:#202124;border-radius:10px;padding:12px}"
        + ".jev-html.jev-simple{background:transparent;color:inherit;border-radius:0;padding:0}"
        + ".jev-plain{font:14.5px/1.45 -apple-system,sans-serif;max-width:760px}"
        // Quoted text hides behind a small ••• pill below the reply.
        + ".jev-body blockquote[type=cite],.jev-body .gmail_quote,.jev-body .yahoo_quoted{display:none!important}"
        + ".jev-message:has(.jev-more[open]) .jev-body blockquote[type=cite],"
        + ".jev-message:has(.jev-more[open]) .jev-body .gmail_quote,"
        + ".jev-message:has(.jev-more[open]) .jev-body .yahoo_quoted{display:block!important}"
        + ".jev-more{margin-top:8px}"
        + ".jev-more>summary{list-style:none;display:inline-block;cursor:default;padding:0 8px;border-radius:8px;"
        + "background:rgba(128,128,128,.18);color:#6b6b6b;font:700 11px/15px -apple-system,sans-serif;letter-spacing:1px}"
        + ".jev-more>summary::-webkit-details-marker{display:none}"
        + ".jev-more>summary:hover,.jev-more[open]>summary{background:rgba(128,128,128,.3)}"
        + "@media (prefers-color-scheme:dark){"
        + "body{color:#e8e8ea}"
        + ".jev-address,.jev-date,.jev-snippet,.jev-meta,.jev-more>summary{color:#a0a0a5}"
        + ".jev-simple a,.jev-plain a{color:#6cb4ff}}"
        + "</style>"

    private static let markShadow = "{box-shadow:inset 3px 0 0 #0a84ff;box-shadow:inset 3px 0 0 -apple-system-control-accent}"

    /// The mark on the reply the actions use, added each time the document loads. A sender link
    /// then moves it in place, so after a reload it always names the selected reply.
    static func mark(_ rowID: Int64, pick: String) -> String {
        "<style>body:not(:has(.jev-message:target)) #" + pick + String(rowID) + markShadow + "</style>"
    }

    /// True for HTML that is only text: no layout, images, or colors of its own. Such a message
    /// follows the page's appearance. Any designed message keeps a white page, so it reads as sent.
    static func isSimple(_ html: String) -> Bool {
        let text = html.lowercased()
        return !["<table", "<img", "<style", "<font", "bgcolor", "background", "color"].contains { text.contains($0) }
    }

    /// The same colours as `MailAvatar`, for the initials beside each reply.
    static func avatarColor(_ address: String) -> String {
        let colors = ["#0a84ff", "#ff9f0a", "#30d158", "#bf5af2", "#ff375f", "#40c8e0", "#5e5ce6", "#ac8e68", "#63e6e2", "#ff453a"]
        return colors[MailAvatar.paletteIndex(for: address.lowercased())]
    }

    /// `quotesOpen` shows every reply's quoted text, as Show Quoted Text in the ⋯ menu and ⌘K asks.
    static func render(_ entries: [Entry], prefersPlain: Bool, quotesOpen: Bool = false, pick: String = defaultPick) -> String {
        guard !entries.isEmpty else { return style }
        let collapses = entries.count > openReplies + 1
        return style + entries.enumerated().map { index, entry in
            let message = entry.message
            let id = String(message.rowID)
            // An unread reply, or one whose text is missing, always starts open.
            let open = !collapses || index < openReplies || !message.read || entry.body == nil
            let initials = MailStyle.initials(message.senderName.isEmpty ? message.senderAddress : message.senderName)
            var summary = "<summary><div class=\"jev-row\">"
            summary += "<span class=\"jev-avatar\" aria-hidden=\"true\" style=\"background-color:" + avatarColor(message.senderAddress) + "\">"
                + MailHTML.escape(initials) + "</span>"
            summary += "<a class=\"jev-from\" href=\"#" + pick + id + "\">" + MailHTML.escape(message.sender) + "</a>"
            if !message.senderName.isEmpty { summary += "<span class=\"jev-address\">&lt;" + MailHTML.escape(message.senderAddress) + "&gt;</span>" }
            summary += "<span class=\"jev-snippet\">" + MailHTML.escape(MailConversationSummaryRow.preview(message.snippet)) + "</span>"
            summary += "<span class=\"jev-date\" title=\"" + MailHTML.escape(MailDates.full(message.date)) + "\">"
                + MailHTML.escape(MailDates.short(message.date)) + "</span>"
            summary += "</div></summary>"
            var facts = ""
            if let detail = entry.body?.message {
                if let to = detail.header("To") { facts += "<span class=\"jev-meta\">To: " + MailHTML.escape(to) + "</span>" }
                if !detail.attachments.isEmpty {
                    facts += "<span class=\"jev-meta\">Attachments: " + MailHTML.escape(detail.attachments.map(\.name).joined(separator: ", ")) + "</span>"
                }
            }
            var content: String
            if let body = entry.body {
                if !prefersPlain, let html = body.html {
                    content = "<div class=\"jev-html" + (isSimple(html) ? " jev-simple" : "") + "\">"
                        + MailHTML.threadFragment(html, className: "jev-body-" + id) + "</div>"
                    if html.range(of: #"(?is)blockquote\b[^>]*type\s*=\s*["']?cite|gmail_quote|yahoo_quoted"#, options: .regularExpression) != nil {
                        content += "<details class=\"jev-more\"" + (quotesOpen ? " open" : "") + "><summary title=\"Show or hide quoted text\" aria-label=\"Quoted text\">•••</summary></details>"
                    }
                } else { content = "<div class=\"jev-plain\">" + MailHTML.plain(body.message.readableText) + "</div>" }
            } else { content = "<p class=\"jev-plain\">This message has not downloaded yet.</p>" }
            let line = facts.isEmpty ? "" : "<div class=\"jev-facts\">" + facts + "</div>"
            return "<details id=\"" + pick + id + "\" class=\"jev-message\"" + (open ? " open" : "") + ">" + summary + line
                + "<div class=\"jev-body\">" + content + "</div></details>"
        }.joined()
    }
}
