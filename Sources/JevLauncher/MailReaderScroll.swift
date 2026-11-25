import AppKit
import SwiftUI
import WebKit
import LauncherCore

/// Space and ⇧Space in the open message: one page down or up, and the next message once Space
/// finds the end. Plain text scrolls its scroll view to an offset that `MailPageScroll` works out.
/// HTML mail runs no scripts, and a web view on the Mac has no scroll view to read, so it scrolls
/// with AppKit's own page keys. Each Space compares a small, low-resolution picture of the page
/// taken just before its own page down with one taken after the scroll settles: when that press
/// moved nothing, the end shows and the next message opens.
///
/// Limits, without a script to measure the page: the end takes one more press than plain text
/// (the press that moves nothing). A page that changes by itself, such as an animated image,
/// can look as if it moved, so that press does not count as the end. A page shorter than the
/// view moves nothing at the first press, so it goes on at once. A press while one is measured
/// is ignored, and a measurement for a page that has changed since is dropped.
@MainActor
final class MailReaderScroll {
    private weak var scrollView: NSScrollView?
    private weak var webView: WKWebView?
    /// Counts the documents shown. A measurement made for another document is dropped.
    private(set) var document = 0
    /// True while a Space in a web page is measured. Presses meanwhile are ignored.
    private(set) var measuring = false
    /// The web document that has committed with content of its own. Until the current document
    /// has, Space does nothing: a page that has not drawn yet looks the same before and after a
    /// page down, which would count as its end and skip the message.
    private(set) var readyDocument: Int?
    /// True when the web page on screen has committed with content, so Space may page through it.
    var webPageReady: Bool { readyDocument == document }
    /// How long a page down may take to settle, and how often it is looked at meanwhile.
    var settle: (step: UInt64, limit: Int) = (120_000_000, 6)

    func attach(_ view: NSScrollView) {
        guard scrollView !== view else { return }
        scrollView = view; webView = nil; document += 1
    }

    func attach(_ view: WKWebView) {
        guard webView !== view else { return }
        webView = view; scrollView = nil; document += 1
    }

    /// The web view shows another document, such as another message: a measurement under way
    /// no longer counts.
    func documentChanged(_ view: WKWebView) { if webView === view { document += 1 } }

    /// The web view committed document number `shown`, which has content. Space may page it now.
    func documentReady(_ view: WKWebView, document shown: Int) {
        if webView === view, document == shown { readyDocument = shown }
    }

    /// Scrolls one page. Calls `atEnd` when Space found the end of the message.
    func page(down: Bool, atEnd: @escaping @MainActor () -> Void) {
        if let scrollView, scrollView.window != nil { page(scrollView, down: down, atEnd: atEnd) }
        else if let webView, webView.window != nil { page(webView, down: down, atEnd: atEnd) }
    }

    private func page(_ view: NSScrollView, down: Bool, atEnd: @MainActor () -> Void) {
        guard let document = view.documentView else { return }
        let clip = view.contentView
        let viewport = Double(clip.bounds.height), content = Double(document.frame.height)
        let top = document.isFlipped ? Double(clip.bounds.minY) : content - Double(clip.bounds.maxY)
        switch MailPageScroll.step(offset: top, viewport: viewport, content: content, down: down) {
        case .scroll(let offset):
            let y = document.isFlipped ? offset : content - offset - viewport
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: CGFloat(y)))
            view.reflectScrolledClipView(clip)
        case .next: atEnd()
        case .stay: break
        }
    }

    /// One press in a web page: a picture, the page key, a wait until the page stops moving, and a
    /// second picture. Only this press's two pictures are compared.
    private func page(_ view: WKWebView, down: Bool, atEnd: @escaping @MainActor () -> Void) {
        guard !measuring, webPageReady else { return }
        measuring = true
        let shown = document
        Task { @MainActor [weak self, weak view] in
            defer { self?.measuring = false }
            guard let self, let view, let before = await self.picture(view, document: shown) else { return }
            if down { view.scrollPageDown(nil) } else { view.scrollPageUp(nil) }
            guard let after = await self.settled(view, document: shown, from: before) else { return }
            guard Self.nearlySame(before, after) else { return }
            // Nothing moved. Down: the end shows. Up: WebKit drops the first page up while the
            // page rests at its end, so it is asked once more; at the top that moves nothing.
            if down { atEnd() } else { view.scrollPageUp(nil) }
        }
    }

    /// The picture once the page has stopped moving, or nil when the document changed meanwhile.
    private func settled(_ view: WKWebView, document shown: Int, from start: Data) async -> Data? {
        var last = start
        for step in 0..<settle.limit {
            try? await Task.sleep(nanoseconds: settle.step)
            guard let next = await picture(view, document: shown) else { return nil }
            // Two pictures alike in a row: the scroll is over. The first look may still show the start.
            if step > 0, Self.nearlySame(last, next) { return next }
            last = next
        }
        return last
    }

    /// A small picture of the page, or nil when the view shows another document or is gone.
    private func picture(_ view: WKWebView, document shown: Int) async -> Data? {
        guard webView === view, document == shown, view.window != nil else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Self.side)
        let image = try? await view.takeSnapshot(configuration: configuration)
        guard webView === view, document == shown else { return nil }
        return image.flatMap(Self.fingerprint)
    }

    /// True when two small pictures differ by no more than a point of scrolling would.
    static func nearlySame(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count) < 2
    }

    /// The width, in points, of the picture each look takes, and the side of the square it is
    /// drawn into: small, so a look is cheap.
    static let side = 96

    /// The page drawn small, enough to see whether it moved.
    static func fingerprint(_ image: NSImage) -> Data? {
        guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = Self.side
        var bytes = Data(count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }
}

/// Placed inside a SwiftUI scroll view: hands its AppKit scroll view to `MailReaderScroll`.
struct MailScrollProbe: NSViewRepresentable {
    let scroll: MailReaderScroll

    final class Probe: NSView {
        var scroll: MailReaderScroll?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
        func attach() { if window != nil, let found = enclosingScrollView { scroll?.attach(found) } }
    }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.scroll = scroll
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.scroll = scroll
        DispatchQueue.main.async { view.attach() }
    }
}
