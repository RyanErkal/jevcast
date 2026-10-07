import AppKit
import SwiftUI

/// The composer's formatting controls, as in Apple Mail: font, size, colour, bold, italic,
/// underline, strikethrough, alignment, lists, indent, link, image, and attachment.
struct MailFormattingBar: View {
    let commands: MailEditorCommands
    let addLink: () -> Void
    let insertImage: () -> Void
    let attach: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full.fixedSize(horizontal: true, vertical: false)
            compact
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }

    private var full: some View {
        HStack(spacing: 10) {
            fontMenu
            sizeMenu
            colorMenu
            divider
            button("bold", "Bold") { commands.trait(.boldFontMask) }
            button("italic", "Italic") { commands.trait(.italicFontMask) }
            button("underline", "Underline") { commands.underline() }
            button("strikethrough", "Strikethrough") { commands.strikethrough() }
            divider
            button("text.alignleft", "Align left") { commands.align(.left) }
            button("text.aligncenter", "Centre") { commands.align(.center) }
            button("text.alignright", "Align right") { commands.align(.right) }
            divider
            button("list.bullet", "Bulleted list") { commands.list(numbered: false) }
            button("list.number", "Numbered list") { commands.list(numbered: true) }
            button("decrease.indent", "Decrease indent") { commands.indent(by: -MailEditorCommands.indentStep) }
            button("increase.indent", "Increase indent") { commands.indent(by: MailEditorCommands.indentStep) }
            divider
            button("link", "Add a link to selected text", addLink)
            button("photo", "Insert an image", insertImage)
            button("paperclip", "Attach files", attach)
        }
    }

    private var compact: some View {
        HStack(spacing: 10) {
            fontMenu
            sizeMenu
            colorMenu
            button("bold", "Bold") { commands.trait(.boldFontMask) }
            button("italic", "Italic") { commands.trait(.italicFontMask) }
            button("underline", "Underline") { commands.underline() }
            Menu {
                Button("Strikethrough") { commands.strikethrough() }
                Section("Alignment") {
                    Button("Align Left") { commands.align(.left) }
                    Button("Centre") { commands.align(.center) }
                    Button("Align Right") { commands.align(.right) }
                }
                Section("Lists") {
                    Button("Bulleted List") { commands.list(numbered: false) }
                    Button("Numbered List") { commands.list(numbered: true) }
                    Button("Decrease Indent") { commands.indent(by: -MailEditorCommands.indentStep) }
                    Button("Increase Indent") { commands.indent(by: MailEditorCommands.indentStep) }
                }
                Button("Add Link", action: addLink)
                Button("Insert Image", action: insertImage)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("More formatting options")
            button("paperclip", "Attach files", attach)
        }
    }

    private var fontMenu: some View {
        Menu {
            ForEach(MailEditorCommands.families, id: \.self) { family in
                Button(family) { commands.family(family == MailEditorCommands.systemFamily ? nil : family) }
            }
        } label: { Text("Font") }.menuStyle(.borderlessButton).fixedSize().help("Font")
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(MailEditorCommands.sizes, id: \.self) { size in Button("\(Int(size))") { commands.size(size) } }
        } label: { Text("Size") }.menuStyle(.borderlessButton).fixedSize().help("Text size")
    }

    private var colorMenu: some View {
        Menu {
            ForEach(MailEditorCommands.colors, id: \.name) { choice in Button(choice.name) { commands.color(choice.color) } }
        } label: { Image(systemName: "paintpalette") }.menuStyle(.borderlessButton).fixedSize().help("Text colour")
    }

    private var divider: some View { Divider().frame(height: 14) }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.help(help)
    }
}

/// Styles the selection, or what you type next when nothing is selected. Each change goes to the
/// draft through the editor's normal change notice.
extension MailEditorCommands {
    nonisolated static let systemFamily = "System"
    /// Families every Mac and common mail program has, so the recipient sees the same font.
    nonisolated static let families = [systemFamily, "Helvetica", "Arial", "Georgia", "Times New Roman", "Courier New", "Verdana"]
    nonisolated static let sizes: [CGFloat] = [10, 12, 13, 14, 16, 18, 24, 32]
    static let colors: [(name: String, color: NSColor?)] = [("Default", nil)] + MailRichText.palette.map { ($0.name, MailRichText.color($0.hex)) }
    nonisolated static let indentStep: CGFloat = 24
    nonisolated static let bullet = "•\t"

    func family(_ name: String?) {
        let manager = NSFontManager.shared
        restyleFont { font in
            guard let name else {
                let system = NSFont.systemFont(ofSize: font.pointSize)
                return manager.convert(system, toHaveTrait: manager.traits(of: font).intersection([.boldFontMask, .italicFontMask]))
            }
            return manager.convert(font, toFamily: name)
        }
    }

    func size(_ points: CGFloat) { restyleFont { NSFontManager.shared.convert($0, toSize: points) } }

    /// Nil goes back to the default text colour, which follows light and dark mode.
    func color(_ color: NSColor?) { setAttribute(.foregroundColor, to: color ?? NSColor.textColor) }

    func strikethrough() {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let current = range.length > 0 ? view.textStorage?.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int
            : view.typingAttributes[.strikethroughStyle] as? Int
        setAttribute(.strikethroughStyle, to: (current ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : nil)
    }

    func align(_ alignment: NSTextAlignment) {
        restyleParagraphs { style in style.alignment = alignment }
    }

    func indent(by delta: CGFloat) {
        restyleParagraphs { style in
            let value = min(max(0, style.headIndent + delta), 10 * Self.indentStep)
            style.headIndent = value; style.firstLineHeadIndent = value
        }
    }

    /// Adds "•" or "1." at the start of each selected line, or takes it away when every line has one.
    /// The marks are text, so the plain part and every mail program show the same list.
    func list(numbered: Bool) {
        guard let view = textView, let storage = view.textStorage else { return }
        let text = storage.string as NSString
        let lines = paragraphRanges(in: text, covering: view.selectedRange())
        let marker = { (index: Int) in numbered ? "\(index + 1).\t" : Self.bullet }
        let present = lines.allSatisfy { Self.listMarker(in: text.substring(with: $0)) != nil }
        let attributes = view.typingAttributes
        storage.beginEditing()
        // From the end, so earlier ranges stay valid while lines change length.
        for (index, line) in lines.enumerated().reversed() {
            let existing = Self.listMarker(in: text.substring(with: line))
            if present {
                if let existing { storage.deleteCharacters(in: NSRange(location: line.location, length: existing)) }
            } else {
                if let existing { storage.deleteCharacters(in: NSRange(location: line.location, length: existing)) }
                storage.insert(NSAttributedString(string: marker(index), attributes: attributes), at: line.location)
            }
        }
        storage.endEditing()
        view.didChangeText()
        view.window?.makeFirstResponder(view)
    }

    /// The length of a "•\t" or "12.\t" mark at the start of a line.
    nonisolated static func listMarker(in line: String) -> Int? {
        if line.hasPrefix(bullet) { return (bullet as NSString).length }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(".\t") else { return nil }
        return digits.count + 2
    }

    // MARK: Helpers

    private func restyleFont(_ change: @escaping (NSFont) -> NSFont) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        let base = view.typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        if range.length == 0 { view.typingAttributes[.font] = change(base) }
        else {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { font, run, _ in storage.addAttribute(.font, value: change(font as? NSFont ?? base), range: run) }
            storage.endEditing()
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }

    private func setAttribute(_ key: NSAttributedString.Key, to value: Any?) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            if let value { view.typingAttributes[key] = value } else { view.typingAttributes.removeValue(forKey: key) }
        } else {
            storage.beginEditing()
            if let value { storage.addAttribute(key, value: value, range: range) } else { storage.removeAttribute(key, range: range) }
            storage.endEditing()
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }

    private func restyleParagraphs(_ change: (NSMutableParagraphStyle) -> Void) {
        guard let view = textView, let storage = view.textStorage else { return }
        let text = storage.string as NSString
        let typing = (view.typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default).mutableCopy() as! NSMutableParagraphStyle
        change(typing)
        view.typingAttributes[.paragraphStyle] = typing
        guard text.length > 0 else { view.window?.makeFirstResponder(view); return }
        storage.beginEditing()
        for line in paragraphRanges(in: text, covering: view.selectedRange()) where line.length > 0 || line.location < text.length {
            let length = max(line.length, line.location < text.length ? 1 : 0)
            let current = storage.attribute(.paragraphStyle, at: min(line.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle ?? .default
            let style = current.mutableCopy() as! NSMutableParagraphStyle
            change(style)
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: line.location, length: min(length, text.length - line.location)))
        }
        storage.endEditing()
        view.didChangeText()
        view.window?.makeFirstResponder(view)
    }

    /// The lines the selection touches, each without its line break.
    private func paragraphRanges(in text: NSString, covering selection: NSRange) -> [NSRange] {
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var ranges: [NSRange] = []
        var location = min(selection.location, text.length)
        let end = min(NSMaxRange(selection), text.length)
        repeat {
            let paragraph = text.paragraphRange(for: NSRange(location: min(location, max(0, text.length - 1)), length: 0))
            var content = paragraph
            while content.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) { content.length -= 1 }
            if location >= text.length, NSMaxRange(paragraph) <= location {
                ranges.append(NSRange(location: text.length, length: 0))
                break
            }
            ranges.append(content)
            location = NSMaxRange(paragraph)
        } while location < end
        return ranges
    }
}
