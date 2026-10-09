import AppKit
import Foundation
import PDFKit

/// Printing is exposed as a user-action helper so the reader can add a Print button without
/// opening a mail window. Tests can inspect makeOperation without presenting a print panel.
enum MailAttachmentPrinter {
    @MainActor
    static func makeOperation(for url: URL) -> NSPrintOperation? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let page = NSSize(width: 612, height: 792)
        if let image = NSImage(contentsOf: url) {
            let view = NSImageView(frame: NSRect(origin: .zero, size: page))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageAlignment = .alignCenter
            return NSPrintOperation(view: view)
        }
        if let document = PDFDocument(url: url) {
            let view = PDFView(frame: NSRect(origin: .zero, size: page))
            view.document = document
            view.autoScales = true
            return NSPrintOperation(view: view)
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let view = NSTextView(frame: NSRect(x: 24, y: 24, width: page.width - 48, height: page.height - 48))
            view.string = text
            view.isEditable = false
            view.font = .systemFont(ofSize: 12)
            return NSPrintOperation(view: view)
        }
        return nil
    }

    /// The only method that presents UI, and it is intended to be called from an explicit button.
    @MainActor
    @discardableResult
    static func print(_ url: URL) -> Bool {
        guard let operation = makeOperation(for: url) else { return false }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation.run()
    }
}
