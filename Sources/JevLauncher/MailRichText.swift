import AppKit
import LauncherCore

/// Export only text and the styles the editor permits. This never reads a file or loads HTML.
enum MailRichText {
    /// The colours the editor offers, as sRGB hex. Only these are written: RTF stores the default
    /// text colour as plain black or white, and white text would vanish for the reader.
    static let palette: [(name: String, hex: UInt32)] = [
        ("Grey", 0x737378), ("Red", 0xd92e29), ("Orange", 0xed7814), ("Green", 0x299945), ("Blue", 0x1a6be6), ("Purple", 0x8045d9)
    ]

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// The palette colour `color` is, allowing for RTF's rounding, or nil for any other colour.
    static func paletteHex(_ color: NSColor) -> UInt32? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return palette.first { entry in
            zip(parts, [Int((entry.hex >> 16) & 0xff), Int((entry.hex >> 8) & 0xff), Int(entry.hex & 0xff)]).allSatisfy { abs($0 - $1) <= 2 }
        }?.hex
    }

    static func attributed(_ data: Data?, plain: String) -> NSAttributedString {
        if let data, data.count <= 4 * 1024 * 1024,
           let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           value.string == plain {
            return value
        }
        return NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
    }

    /// One `<div>` per line, with its alignment and indent, and inline styles for font, size,
    /// weight, slant, palette colour, underline, strikethrough, and links. Default text has no
    /// colour, so the reader's own light or dark text shows.
    static func html(_ data: Data?, plain: String) -> String {
        let value = attributed(data, plain: plain)
        let text = value.string as NSString
        var output = "<div style=\"white-space:pre-wrap\">"
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            while content.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) { content.length -= 1 }
            let style = value.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            output += "<div" + paragraphStyle(style) + ">" + (content.length == 0 ? "<br>" : runs(value, in: content)) + "</div>"
            location = NSMaxRange(paragraph)
        }
        return output + "</div>"
    }

    private static func paragraphStyle(_ style: NSParagraphStyle?) -> String {
        guard let style else { return "" }
        var css: [String] = []
        switch style.alignment {
        case .center: css.append("text-align:center")
        case .right: css.append("text-align:right")
        case .justified: css.append("text-align:justify")
        default: break
        }
        if style.headIndent > 0 { css.append("margin-left:\(Int(min(style.headIndent, 400)))px") }
        return css.isEmpty ? "" : " style=\"" + css.joined(separator: ";") + "\""
    }

    private static func runs(_ value: NSAttributedString, in range: NSRange) -> String {
        var output = ""
        value.enumerateAttributes(in: range) { attributes, run, _ in
            var styles: [String] = []
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if let family = family(font) { styles.append("font-family:" + family) }
                if traits.contains(.boldFontMask) { styles.append("font-weight:bold") }
                if traits.contains(.italicFontMask) { styles.append("font-style:italic") }
                styles.append("font-size:\(Int(min(72, max(8, font.pointSize))))px")
            }
            if let color = attributes[.foregroundColor] as? NSColor, let hex = paletteHex(color) { styles.append(String(format: "color:#%06x", hex)) }
            var lines: [String] = []
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 { lines.append("underline") }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { lines.append("line-through") }
            if !lines.isEmpty { styles.append("text-decoration:" + lines.joined(separator: " ")) }
            var text = MailHTML.escape((value.string as NSString).substring(with: run))
            if !styles.isEmpty { text = "<span style=\"" + styles.joined(separator: ";") + "\">" + text + "</span>" }
            let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
            if let link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                text = "<a href=\"" + MailHTML.escape(link.absoluteString) + "\">" + text + "</a>"
            }
            output += text
        }
        return output
    }

    /// A CSS family list for a font the editor offers, or nil for the system font.
    private static func family(_ font: NSFont) -> String? {
        guard let name = font.familyName, !name.hasPrefix("."), MailEditorCommands.families.contains(name) else { return nil }
        let fallback: String
        switch name {
        case "Georgia", "Times New Roman": fallback = "serif"
        case "Courier New": fallback = "monospace"
        default: fallback = "sans-serif"
        }
        return "'" + name + "'," + fallback
    }
}
