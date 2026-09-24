import AppKit

/// Puts dictated text into the front app: paste with ⌘V, then put the old clipboard back.
/// Without Accessibility the text stays on the clipboard for the user to paste.
@MainActor
enum TextInserter {
    enum Outcome: Equatable { case pasted, onClipboard }
    static let restoreDelay: UInt64 = 600_000_000

    static func insert(_ text: String, pasteboard: NSPasteboard = .general) -> Outcome {
        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .onClipboard
        }
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        // Transient, so clipboard history skips it.
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let change = pasteboard.changeCount
        postPaste()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: restoreDelay)
            // Something else copied in the meantime; keep it.
            guard pasteboard.changeCount == change else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return .pasted
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
}
