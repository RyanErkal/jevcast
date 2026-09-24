import SwiftUI
import WebKit

/// Shows an HTML email with nothing loaded from the network: no remote images, no tracking
/// pixels, no scripts. A strict Content-Security-Policy and disabled JavaScript enforce it.
/// Clicked links open in the default browser.
struct MailHTMLView: NSViewRepresentable {
    let html: String

    /// Allows only inline styles and images embedded in the message itself.
    static let policy = "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:"

    static func document(_ html: String) -> String {
        // DNS prefetch is outside the policy, so it is turned off too.
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta http-equiv=\"x-dns-prefetch-control\" content=\"off\"><meta charset=\"utf-8\">"
        let style = "<style>body{font:13px -apple-system,sans-serif;margin:0;word-wrap:break-word}img{max-width:100%;height:auto}</style>"
        return meta + style + html
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
        guard context.coordinator.shown != html else { return }
        context.coordinator.shown = html
        view.loadHTMLString(Self.document(html), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Only the message itself loads. A click on a web or mail link opens outside Jevcast.
            if action.navigationType == .linkActivated, let url = action.request.url {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            let scheme = action.request.url?.scheme?.lowercased() ?? "about"
            decisionHandler(scheme == "about" && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }
    }
}
