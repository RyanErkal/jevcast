import AppKit
import SwiftUI

@MainActor
final class MailEditorCommands: ObservableObject {
    weak var textView: NSTextView?
    func trait(_ trait: NSFontTraitMask) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        let base = view.typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        let manager = NSFontManager.shared
        let removing = manager.traits(of: base).contains(trait)
        let convert: (NSFont) -> NSFont = { removing ? manager.convert($0, toNotHaveTrait: trait) : manager.convert($0, toHaveTrait: trait) }
        if range.length == 0 { view.typingAttributes[.font] = convert(base) }
        else {
            storage.enumerateAttribute(.font, in: range) { font, run, _ in storage.addAttribute(.font, value: convert(font as? NSFont ?? base), range: run) }
            view.didChangeText()
        }
        view.window?.makeFirstResponder(view)
    }
    func underline() { textView?.underline(nil); textView?.didChangeText() }
    func link(_ url: URL) {
        guard let view = textView, view.selectedRange().length > 0 else { return }
        view.textStorage?.addAttribute(.link, value: url, range: view.selectedRange()); view.didChangeText()
    }
}

struct MailRichEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtf: Data?
    let commands: MailEditorCommands
    var focus: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = MailCompositionTextView()
        view.isRichText = true; view.importsGraphics = false; view.allowsImageEditing = false
        view.drawsBackground = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainerInset = NSSize(width: 12, height: 10)
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.allowsUndo = true; view.isAutomaticQuoteSubstitutionEnabled = false
        view.delegate = context.coordinator; scroll.documentView = view
        commands.textView = view
        view.textStorage?.setAttributedString(MailRichText.attributed(rtf, plain: text))
        context.coordinator.lastRTF = rtf
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text || context.coordinator.lastRTF != rtf {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(MailRichText.attributed(rtf, plain: text))
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            context.coordinator.lastRTF = rtf
        }
        if focus && !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MailRichEditor
        var lastRTF: Data?
        var didFocus = false
        init(_ parent: MailRichEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
            let data = try? storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            lastRTF = data; parent.text = view.string; parent.rtf = data
        }
    }
}

/// A paste inserts text only. Files and images require the explicit attachment picker.
private final class MailCompositionTextView: NSTextView {
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { insertText(text, replacementRange: selectedRange()) }
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
