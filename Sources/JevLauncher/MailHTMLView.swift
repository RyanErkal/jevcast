import SwiftUI
import WebKit
import LauncherCore

/// Shows an HTML email as the sender styled it, with its images. Scripts never run, frames and
/// forms cannot load anything, and clicked links open in the default browser. Web images load
/// unless the user turns them off in the ⋯ menu above a message.
struct MailHTMLView: NSViewRepresentable {
    let html: String
    /// Identifies the message. The prepared content also participates in revision checks.
    var documentID: Int64 = 0
    var inlineImages: [String: MIMEMessage.InlineImage] = [:]
    /// Web images, fonts, and style sheets load when true. Scripts never run either way.
    var loadsRemote = true
    /// Page zoom, 0.75 to 1.5.
    var zoom: Double = 1
    /// Fits wide mail to the pane with a fixed style sheet. No script measures or changes the page.
    var fitsWidth = true
    var selectMessage: ((Int64) -> Void)? = nil
    /// The open message's page keys, for Space and ⇧Space. Nil for a preview, such as a quote.
    var scroll: MailReaderScroll? = nil
    var surface: Surface = .page
    /// A conversation's sender links start with this fragment. A click marks that reply and selects
    /// it. The prefix is new for each conversation shown, so a sender's own links cannot copy it.
    var pickPrefix: String? = nil
    /// The reply the reader's actions use, in a conversation. Each time the document loads, this
    /// reply has the mark, so the mark and the actions always agree.
    var marked: Int64? = nil
    /// False while the document is only a style, such as a conversation whose first reply has not
    /// loaded: Space then waits instead of taking the empty page for the end of the message.
    var hasContent = true

    /// Where the document sits. A page is an opaque white web page, as in Mail; the reader's
    /// text message and conversation draw on the pane's own surface, so the reader has one
    /// background and nothing flashes while a document loads.
    enum Surface: Equatable {
        case page
        /// A message of text in the reader: its text follows the appearance.
        case message
        /// A designed message in the reader. The sender's page is not changed: the view itself is
        /// a light, rounded card, and the reader insets it on the pane.
        case card
        /// A conversation document, which brings its own style.
        case thread
    }

    /// The reader's surface for a message: text on the pane, or a designed message on a card.
    static func readerSurface(_ html: String) -> Surface { MailThreadHTML.isSimple(html) ? .message : .card }

    static func policy(remote: Bool) -> String {
        remote ? "default-src 'none'; img-src data: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:"
               : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
    }

    /// A fixed style that makes fixed-width layouts shrink to the pane. It wins over the sender's widths.
    static let fitStyle = "<style>html,body{max-width:100%!important;overflow-x:auto!important}"
        + "table,td,th,div,center,p,img,video{max-width:100%!important;box-sizing:border-box}"
        + "table{width:auto!important;table-layout:auto!important}td,th{width:auto!important}"
        + "img{height:auto!important}pre{white-space:pre-wrap!important}"
        + "*{word-wrap:break-word;overflow-wrap:anywhere}</style>"
    /// For a message that is only text: no layout, images, or colors of its own. It follows the
    /// Mac's light or dark appearance and keeps lines to a width that reads well. A designed message
    /// never gets this, so it shows on the white page its sender expected.
    static let plainStyle = "<style>:root{color-scheme:light dark}:where(body){max-width:760px;font-size:14.5px;line-height:1.45}"
        + "@media (prefers-color-scheme:dark){:where(body){background:#1c1c1e;color:#e8e8ea}:where(a){color:#6cb4ff}}</style>"
    /// A message of text in the reader: the same as `plainStyle`, but on the pane's own surface.
    static let readerPlainStyle = "<style>:root{color-scheme:light dark}html,body{background:transparent!important}"
        + ":where(body){max-width:760px;font-size:14.5px;line-height:1.45;margin:14px}"
        + "@media (prefers-color-scheme:dark){:where(body){color:#e8e8ea}:where(a){color:#6cb4ff}}</style>"
    /// Without fitting, the page still scrolls both ways when it is wider than the pane.
    static let scrollStyle = "<style>html,body{overflow:auto!important}</style>"

    /// The message's own images put in place of their `cid:` links. The costly step, so the mail
    /// model runs it off the main thread and keeps the result.
    nonisolated static func inlining(_ html: String, images: [String: MIMEMessage.InlineImage]) -> String {
        var body = html
        for (cid, image) in images {
            body = body.replacingOccurrences(of: "cid:" + cid, with: "data:\(image.mimeType);base64," + image.data.base64EncodedString())
        }
        return body
    }

    /// The message with its own images inlined, a content policy first, and only a light default
    /// style that the sender's styling overrides. A designed message keeps its own page colours:
    /// nothing here sets the colour of its `html` or `body`. `mark` is the conversation's mark style.
    static func document(_ html: String, inlineImages: [String: MIMEMessage.InlineImage] = [:], remote: Bool = true,
                         fitsWidth: Bool = false, surface: Surface = .page, mark: String = "") -> String {
        let body = inlineImages.isEmpty ? html : inlining(html, images: inlineImages)
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy(remote: remote))\"><meta charset=\"utf-8\">"
        let style = "<style>:where(body){font:14px -apple-system,sans-serif;margin:12px;word-wrap:break-word}:where(img){max-width:100%;height:auto}</style>"
        let simple = (surface == .page || surface == .message) && MailThreadHTML.isSimple(html)
        let lead = !simple ? "" : surface == .message ? readerPlainStyle : plainStyle
        // Appended after the body so these rules come last and override the sender's own style sheets.
        return meta + style + lead + body + (fitsWidth ? fitStyle : scrollStyle) + mark
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        Self.applySurface(surface, to: view)
        context.coordinator.surface = surface
        view.navigationDelegate = context.coordinator
        return view
    }

    /// A page and a card are white, as in Mail, because most HTML mail assumes one; the mail's own
    /// page colour paints over it. A card stays light in dark appearance and has round corners.
    /// For text and conversations the view draws nothing of its own, so the pane shows through.
    static func applySurface(_ surface: Surface, to view: WKWebView) {
        let clear = surface == .message || surface == .thread
        view.setValue(!clear, forKey: "drawsBackground")
        view.underPageBackgroundColor = clear ? .clear : surface == .card ? .white : nil
        view.appearance = surface == .card ? NSAppearance(named: .aqua) : nil
        view.wantsLayer = true
        view.layer?.cornerRadius = surface == .card ? 10 : 0
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = surface == .card
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selectMessage = selectMessage
        coordinator.pickPrefix = pickPrefix
        if coordinator.surface != surface { Self.applySurface(surface, to: view); coordinator.surface = surface }
        scroll?.attach(view)
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
        let key = DocumentKey(id: documentID, html: html, images: inlineImages, remote: loadsRemote, fitsWidth: fitsWidth, surface: surface)
        let mark = pickPrefix == nil ? nil : marked
        guard let change = coordinator.state.change(to: key, mark: mark) else { return }
        scroll?.documentChanged(view)
        let markStyle = both(mark, pickPrefix).map { MailThreadHTML.mark($0, pick: $1) } ?? ""
        let navigation = view.loadHTMLString(Self.document(html, inlineImages: inlineImages, remote: loadsRemote, fitsWidth: fitsWidth,
                                                           surface: surface, mark: markStyle), baseURL: nil)
        coordinator.loading(navigation, scroll: scroll, document: scroll?.document, hasContent: hasContent, in: view)
        if change.hides { coordinator.hide(view, until: navigation) }
    }

    /// Shown in place of a message whose document could not load, so the previous message never shows under its header.
    static let failureLine = "<p>This message could not be shown.</p>"

    struct DocumentKey: Equatable {
        let id: Int64
        let html: String
        let images: [String: MIMEMessage.InlineImage]
        let remote: Bool
        let fitsWidth: Bool
        var surface: Surface = .page
    }

    /// What the view shows, and whether a change needs the document loaded again.
    struct LoadState {
        private(set) var shown: DocumentKey?
        /// The reply with the mark: the one marked when the document loaded, or the sender clicked since.
        private(set) var mark: Int64?

        struct Change: Equatable {
            /// True for the first document or another message: an empty view or the old body must
            /// not show under the new header.
            let hides: Bool
        }

        /// The load that shows `key` with `mark`, or nil when the view already shows both. A
        /// selection made outside the document, such as from the list, loads it again so the
        /// mark moves too.
        mutating func change(to key: DocumentKey, mark: Int64?) -> Change? {
            guard shown != key || self.mark != mark else { return nil }
            let hides = shown?.id != key.id
            shown = key
            self.mark = mark
            return Change(hides: hides)
        }

        /// A sender link moved the mark in place, so the selection it makes needs no new load.
        mutating func picked(_ rowID: Int64) { mark = rowID }
    }

    /// What a navigation in the document does.
    enum LinkDecision: Equatable {
        /// The document itself loads.
        case load
        /// A sender link of this conversation: mark that reply and select it.
        case pick(Int64)
        /// A web or mail link: it opens outside Jevcast.
        case open(URL)
        /// Anything else does nothing.
        case block
    }

    /// How long the view may stay hidden while the next message loads, at most.
    static let revealLimit: UInt64 = 600_000_000

    final class Coordinator: NSObject, WKNavigationDelegate {
        var state = LoadState()
        var surface: Surface?
        var selectMessage: ((Int64) -> Void)?
        var pickPrefix: String?
        /// The load the view waits for before it shows again.
        private var pending: WKNavigation?
        /// The message's own load, the reader's Space, and the document number it counts as.
        private var awaiting: (navigation: WKNavigation, document: Int, hasContent: Bool)?
        private weak var scroll: MailReaderScroll?
        /// True while the failure line shows in place of a message that could not load.
        private(set) var showingFailure = false

        /// A new document starts loading. Space may page it once it commits, when it has content.
        func loading(_ navigation: WKNavigation?, scroll: MailReaderScroll?, document: Int?, hasContent: Bool, in view: WKWebView) {
            self.scroll = scroll
            showingFailure = false
            guard let document else { awaiting = nil; return }
            guard let navigation else {
                awaiting = nil
                if hasContent { scroll?.documentReady(view, document: document) }
                return
            }
            awaiting = (navigation, document, hasContent)
        }

        /// Hides the old message until WebKit commits the new one. The pane shows meanwhile, and a
        /// time limit shows the view again whatever happens.
        func hide(_ view: WKWebView, until navigation: WKNavigation?) {
            guard let navigation else { return }
            pending = navigation
            view.alphaValue = 0
            Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(nanoseconds: MailHTMLView.revealLimit)
                guard let self, let view, self.pending === navigation else { return }
                self.reveal(view)
            }
        }

        private func reveal(_ view: WKWebView) {
            pending = nil
            view.alphaValue = 1
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if navigation === pending { reveal(webView) }
            if let awaiting, navigation === awaiting.navigation {
                self.awaiting = nil
                if awaiting.hasContent { scroll?.documentReady(webView, document: awaiting.document) }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === pending { reveal(webView) }
        }

        /// The message's document never committed, so the view still holds the previous one. It
        /// stays hidden and a short failure line loads in its place.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard navigation === pending || navigation === awaiting?.navigation else { return }
            awaiting = nil
            webView.alphaValue = 0
            // The failure line itself failed: the view stays hidden, and the pane shows.
            guard !showingFailure else { pending = nil; return }
            showingFailure = true
            let lineSurface: Surface = surface == .thread || surface == .message ? .message : .page
            pending = webView.loadHTMLString(MailHTMLView.document(MailHTMLView.failureLine, remote: false, surface: lineSurface), baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            switch Self.decision(action.request.url, linkActivated: action.navigationType == .linkActivated,
                                 mainFrame: action.targetFrame?.isMainFrame == true, prefix: pickPrefix) {
            case .load:
                decisionHandler(.allow)
            case .pick(let id):
                // The reply gets its mark within the same document and becomes the one the
                // actions use. Nothing reloads, so the place in the page stays.
                state.picked(id)
                selectMessage?(id)
                decisionHandler(.allow)
            case .open(let url):
                // A mail address starts a new message here. A web link opens in the browser.
                MailLinkRouter.open(url)
                decisionHandler(.cancel)
            case .block:
                decisionHandler(.cancel)
            }
        }

        /// Only the message itself loads, and nothing may navigate the frame away from it. A link
        /// in a message can open a web page or start a mail; only a sender link with this
        /// conversation's prefix selects a reply. No other link reaches the app.
        nonisolated static func decision(_ url: URL?, linkActivated: Bool, mainFrame: Bool, prefix: String?) -> LinkDecision {
            if linkActivated {
                if mainFrame, let id = pickedMessage(url, prefix: prefix) { return .pick(id) }
                if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .open(url) }
                return .block
            }
            let scheme = url?.scheme?.lowercased() ?? "about"
            return scheme == "about" && mainFrame ? .load : .block
        }

        /// The reply a sender link names: `about:blank#<prefix><row id>` in the shown document only.
        /// WebKit hands this link over with its `#` escaped, so the fragment is read from the text.
        nonisolated static func pickedMessage(_ url: URL?, prefix: String?) -> Int64? {
            guard let url, let prefix, !prefix.isEmpty, url.scheme?.lowercased() == "about",
                  let text = url.absoluteString.removingPercentEncoding,
                  let hash = text.firstIndex(of: "#") else { return nil }
            let fragment = text[text.index(after: hash)...]
            guard fragment.hasPrefix(prefix) else { return nil }
            return Int64(fragment.dropFirst(prefix.count))
        }
    }
}

/// Both values, or nil when either is missing.
private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
