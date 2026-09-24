import AppKit

/// Puts dictated text into the front app: paste with ⌘V, then put the old clipboard back.
/// Without Accessibility the text stays on the clipboard for the user to paste.
@MainActor
enum TextInserter {
    enum Outcome: Equatable { case pasted, onClipboard }
    nonisolated static let restoreDelay: UInt64 = 600_000_000
    /// The clipboard to put back after a paste, and the change count of the pasted text.
    private static var pending: (saved: [NSPasteboardItem], change: Int, restore: Task<Void, Never>)?

    static func insert(_ text: String, pasteboard: NSPasteboard = .general, trusted: Bool = AXIsProcessTrusted(),
                       paste: () -> Void = postPaste, delay: UInt64 = restoreDelay) -> Outcome {
        guard trusted else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .onClipboard
        }
        // A second paste before the first restore keeps the user's clipboard, not the first dictation.
        let saved = pending.flatMap { $0.change == pasteboard.changeCount ? $0.saved : nil } ?? snapshot(pasteboard)
        pending?.restore.cancel()
        pending = nil
        pasteboard.clearContents()
        // Transient, so clipboard history skips it.
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let change = pasteboard.changeCount
        paste()
        let restore = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            pending = nil
            // Something else copied in the meantime; keep it.
            guard pasteboard.changeCount == change else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        pending = (saved, change, restore)
        return .pasted
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
    }

    nonisolated static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
}
