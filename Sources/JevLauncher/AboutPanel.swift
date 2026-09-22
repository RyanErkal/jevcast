import AppKit

/// The standard About panel, with the license and project links as credits.
@MainActor
enum AboutPanel {
    /// A menu-bar app is not active, so bring it forward or the panel opens behind other apps.
    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let text = NSMutableAttributedString(string: "Free and open source under the MIT License.\n", attributes: base)
        text.append(NSAttributedString(string: "Website", attributes: base.merging([.link: AppIdentity.website]) { $1 }))
        text.append(NSAttributedString(string: "  ·  ", attributes: base))
        text.append(NSAttributedString(string: "Source code", attributes: base.merging([.link: AppIdentity.repository]) { $1 }))
        return text
    }
}
