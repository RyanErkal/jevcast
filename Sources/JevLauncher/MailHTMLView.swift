import SwiftUI
import WebKit
import LauncherCore

/// Shows an HTML email as the sender styled it, with its images. Scripts never run, frames and
/// forms cannot load anything, and clicked links open in the default browser. Web images load
/// unless the user turns them off in the mail window.
struct MailHTMLView: NSViewRepresentable {
    let html: String
    var inlineImages: [String: MIMEMessage.InlineImage] = [:]
    /// Web images, fonts, and style sheets load when true. Scripts never run either way.
    var loadsRemote = true

    static func policy(remote: Bool) -> String {
        remote ? "default-src 'none'; img-src data: http: https:; style-src 'unsafe-inline' http: https:; font-src data: http: https:"
               : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
    }

    /// The message with its own images inlined, a content policy first, and only a light default
    /// style that the sender's styling overrides.
    static func document(_ html: String, inlineImages: [String: MIMEMessage.InlineImage] = [:], remote: Bool = true) -> String {
        var body = html
        for (cid, image) in inlineImages {
            body = body.replacingOccurrences(of: "cid:" + cid, with: "data:\(image.mimeType);base64," + image.data.base64EncodedString())
        }
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy(remote: remote))\"><meta charset=\"utf-8\">"
        let style = "<style>:where(body){font:14px -apple-system,sans-serif;margin:12px;word-wrap:break-word}:where(img){max-width:100%;height:auto}</style>"
        return meta + style + body
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
        let key = html + (loadsRemote ? "#remote" : "#local")
        guard context.coordinator.shown != key else { return }
        context.coordinator.shown = key
        view.loadHTMLString(Self.document(html, inlineImages: inlineImages, remote: loadsRemote), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?
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
