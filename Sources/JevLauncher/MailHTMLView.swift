import SwiftUI
import WebKit
import LauncherCore

/// Shows an HTML email as the sender styled it, with its images. Scripts never run, frames and
/// forms cannot load anything, and clicked links open in the default browser. Web images load
/// unless the user turns them off in the mail window.
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

    static func policy(remote: Bool) -> String {
        remote ? "default-src 'none'; img-src data: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:"
               : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
    }

    /// The message with its own images inlined, a content policy first, and only a light default
    /// style that the sender's styling overrides.
    /// A fixed style that makes fixed-width layouts shrink to the pane. It wins over the sender's widths.
    static let fitStyle = "<style>html,body{max-width:100%!important;overflow-x:auto!important}"
        + "table,td,th,div,center,p,img,video{max-width:100%!important;box-sizing:border-box}"
        + "table{width:auto!important;table-layout:auto!important}td,th{width:auto!important}"
        + "img{height:auto!important}pre{white-space:pre-wrap!important}"
        + "*{word-wrap:break-word;overflow-wrap:anywhere}</style>"
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

    static func document(_ html: String, inlineImages: [String: MIMEMessage.InlineImage] = [:], remote: Bool = true,
                         fitsWidth: Bool = false) -> String {
        let body = inlineImages.isEmpty ? html : inlining(html, images: inlineImages)
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy(remote: remote))\"><meta charset=\"utf-8\">"
        let style = "<style>:where(body){font:14px -apple-system,sans-serif;margin:12px;word-wrap:break-word}:where(img){max-width:100%;height:auto}</style>"
        // Appended after the body so these rules come last and override the sender's own style sheets.
        return meta + style + body + (fitsWidth ? fitStyle : scrollStyle)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        // A white page, as in Mail, because most HTML mail assumes one.
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
        let key = DocumentKey(id: documentID, html: html, images: inlineImages, remote: loadsRemote, fitsWidth: fitsWidth)
        guard context.coordinator.shown != key else { return }
        context.coordinator.shown = key
        view.loadHTMLString(Self.document(html, inlineImages: inlineImages, remote: loadsRemote, fitsWidth: fitsWidth), baseURL: nil)
    }

    struct DocumentKey: Equatable {
        let id: Int64
        let html: String
        let images: [String: MIMEMessage.InlineImage]
        let remote: Bool
        let fitsWidth: Bool
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: DocumentKey?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Only the message itself loads. A click on a web or mail link opens outside Jevcast.
            if action.navigationType == .linkActivated, let url = action.request.url {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { Frontmost.open(url) }
                decisionHandler(.cancel)
                return
            }
            // The message itself loads, and nothing may navigate the frame away from it.
            let scheme = action.request.url?.scheme?.lowercased() ?? "about"
            decisionHandler(scheme == "about" && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }
    }
}
