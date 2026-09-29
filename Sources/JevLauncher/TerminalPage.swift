import AppKit
import SwiftUI

/// The Terminal view (Hyper–T): your login shell, drawn by libghostty, in the launcher panel.
/// Every key goes to the shell except Escape, which closes the view as in any other view;
/// ⌃[ sends Escape to the program in the shell. The shell keeps running while the launcher is
/// closed, so the next Hyper–T comes back to it. The bar above shows the shell's folder.
@MainActor
final class TerminalPage: ObservableObject, LauncherPage {
    let id = ViewID.terminal
    private let terminal: TerminalView?
    /// Shown in place of the shell in snapshots, or when libghostty cannot start.
    private let placeholder: String
    @Published private(set) var folder: URL?
    private var folderTimer: Timer?

    init(terminal: TerminalView?, placeholder: String) {
        self.terminal = terminal; self.placeholder = placeholder
    }

    var isTyping: Bool { true }
    var inputView: NSView? { terminal }
    var hasFilter: Bool { false }
    var footerHints: [(title: String, key: String)] { [("Escape in Shell", "⌃[")] }
    func handle(_ key: PageKey) -> Bool { false }
    func filter(_ text: String) {}
    func back() -> Bool { false }

    /// The folder is read once a second while the view shows, so it follows `cd`.
    func opened() {
        guard terminal != nil else { return }
        readFolder()
        folderTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readFolder() }
        }
    }
    func closed(handingOff: Bool) {
        folderTimer?.invalidate()
        folderTimer = nil
    }
    private func readFolder() {
        let current = ShellFolder.current()
        if current != folder { folder = current }
    }

    func header() -> AnyView? { AnyView(TerminalFolderBar(page: self)) }

    func content() -> AnyView {
        guard let terminal else {
            return AnyView(Text(placeholder).font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        return AnyView(TerminalHost(terminal: terminal))
    }
}

/// The shell's folder name, then its path as the shell writes it, such as "ryanerkal ~".
private struct TerminalFolderBar: View {
    @ObservedObject var page: TerminalPage
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let folder = page.folder {
                Text(folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent)
                    .font(.system(size: LauncherMetrics.searchFontSize))
                Text(ShellFolder.display(folder))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1).truncationMode(.middle)
        .help(page.folder?.path ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// Puts the one running terminal in the panel. Leaving the view only removes it; the shell stays.
private struct TerminalHost: NSViewRepresentable {
    let terminal: TerminalView
    func makeNSView(context: Context) -> TerminalView { terminal }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
