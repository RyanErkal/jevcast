import Combine
import SwiftUI

/// The keys under a view in the panel. It draws again when the view says its keys changed, such
/// as when a mail reply opens and Escape now discards.
struct PageFooter: View {
    let page: LauncherPage
    let escapeClosesLauncher: Bool
    @State private var revision = 0

    var body: some View {
        // Reading the revision draws the footer again when it changes.
        let _ = revision
        HStack(spacing: 10) {
            Spacer(minLength: 10)
            ForEach(page.footerHints, id: \.key) { hint in KeyHint(hint.title, hint.key) }
            // While a text box in the view has the keys, Return types there.
            if page.hasFilter && !page.isTyping { KeyHint(page.openTitle, "↩") }
            KeyHint(page.backTitle ?? (escapeClosesLauncher ? "Close" : "Back"), "esc")
            if page.canPopOut { KeyHint("Open Window", "⌘O") }
        }
        .font(.system(size: 12))
        .padding(.horizontal, LauncherMetrics.gutter)
        .frame(height: LauncherMetrics.footerHeight)
        .onReceive(page.footerChanges.receive(on: DispatchQueue.main)) { revision &+= 1 }
    }
}
