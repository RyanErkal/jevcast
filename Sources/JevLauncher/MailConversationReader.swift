import SwiftUI
import LauncherCore

/// A single scrolling document displays each reply. Loading does not mark other replies read.
/// A click on a sender marks that reply in place and selects it; the document is not rebuilt for
/// that, so the place you scrolled to stays. Whenever the document loads again, such as after Fit
/// Wide Mail to Width, the selected reply has the mark, so the mark and the actions agree.
struct MailConversationReader: View {
    @ObservedObject var model: MailModel
    let conversation: MailConversation
    let zoom: Double
    let fitsWidth: Bool
    let prefersPlain: Bool
    @State private var entries: [MailThreadHTML.Entry] = []
    /// The rendered document. It is built when a reply loads, not on every redraw of the pane.
    @State private var html = MailThreadHTML.style
    @State private var loading = true
    @State private var attempt = 0
    /// New for each conversation shown, so a sender's own links cannot pick a reply.
    @State private var pick = MailThreadHTML.newPick()

    private var loadKey: String {
        conversation.stableID + ":" + conversation.messages.map { String($0.summary.rowID) }.joined(separator: ",") + ":\(attempt)"
    }

    var body: some View {
        MailHTMLView(html: html,
                     documentID: conversation.latest.summary.rowID, loadsRemote: model.loadsImages,
                     zoom: zoom, fitsWidth: fitsWidth, selectMessage: { id in
            guard conversation.messages.contains(where: { $0.summary.rowID == id }) else { return }
            model.select(id, byUser: true)
        }, scroll: model.readerScroll, surface: .thread, pickPrefix: pick, marked: model.selectedID,
           hasContent: !entries.isEmpty)
        // Notes float over the document, so it never moves down when one shows.
        .overlay(alignment: .topTrailing) {
            Group {
                if loading { MailDelayedSpinner() }
                else if entries.contains(where: { $0.body == nil }) {
                    Button("Retry missing messages") { attempt += 1 }.buttonStyle(.link).font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(8)
        }
        .task(id: loadKey) {
            loading = true
            entries = []
            for item in conversation.messages {
                let body = await model.conversationBody(item.summary)
                guard !Task.isCancelled else { return }
                entries.append(.init(message: item.summary, body: body))
                // The newest replies show while older ones still load.
                if entries.count <= MailThreadHTML.openReplies { html = render() }
            }
            html = render()
            loading = false
        }
        .onChange(of: prefersPlain) { _, _ in html = render() }
        .onChange(of: quotesOpen) { _, _ in html = render() }
        // Another conversation, or the composer in its place: the quotes start closed next time.
        .onDisappear { if model.quotesShownIn == conversation.id { model.quotesShownIn = nil } }
    }

    private var quotesOpen: Bool { model.quotesShownIn == conversation.id }

    private func render() -> String {
        MailThreadHTML.render(entries, prefersPlain: prefersPlain, quotesOpen: quotesOpen, pick: pick)
    }
}
