import SwiftUI
import LauncherCore

/// The open message: its bar, a header drawn at once from the list's data, and the body. Plain
/// text, simple HTML, and conversations sit on the pane's own surface; designed HTML shows as a
/// light card on it. While a body loads, quiet lines hold its place.
struct MailReader: View {
    @ObservedObject var model: MailModel
    /// Shows an Expand button that hides the sidebar and list.
    var expanded: Binding<Bool>? = nil
    var features: MailFeatureCenter? = nil
    @AppStorage(MailReading.zoomKey) private var zoom = 1.0
    @AppStorage(MailReading.fitKey) private var fitsWidth = true
    @AppStorage(MailReading.plainKey) private var prefersPlain = false

    var body: some View {
        if let message = model.selected {
            let conversation = model.shownThread
            VStack(alignment: .leading, spacing: 0) {
                MailReaderToolbar(model: model, message: message, expanded: expanded, features: features,
                                  zoom: $zoom, fitsWidth: $fitsWidth, prefersPlain: $prefersPlain)
                Divider()
                MailReaderHeader(model: model, message: message, detail: model.detail, unsubscribe: unsubscribe,
                                 replies: conversation?.messages.count ?? 1)
                if let detail = model.detail, !detail.attachments.isEmpty {
                    MailReceivedAttachments(model: model, message: message, detail: detail)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
                Divider()
                // An invitation shows as a card with its answer buttons, above the message.
                if let invite = model.invite { MailInviteCard(model: model, invite: invite) }
                if let summary = model.summary {
                    GroupBox { Text(summary).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        label: { Label("AI summary", systemImage: "sparkles") }
                        .padding(12)
                }
                Group {
                    if let conversation {
                        MailConversationReader(model: model, conversation: conversation,
                            zoom: MailReading.clampZoom(zoom), fitsWidth: fitsWidth, prefersPlain: prefersPlain)
                            .id(conversation.id)
                    } else { body(message) }
                }
                // Scrolling or clicking in the message counts as using it, as Space does.
                .background { MailReaderActivity { model.noteUserAction() } }
            }
        } else {
            MailEmptyState(symbol: "envelope.open", title: "No message selected", detail: "Use ↑ and ↓ to pick one, or ⌘N to write.")
        }
    }

    /// Unsubscribe shows only when Jevcast can act on it.
    private var unsubscribe: MailUnsubscribe? {
        guard let unsubscribe = model.unsubscribe, unsubscribe.web != nil || NativeMailCenter.isActive else { return nil }
        return unsubscribe
    }

    @ViewBuilder private func body(_ message: MailSummary) -> some View {
        if let detail = model.detail {
            // The message as the sender styled it, with its images. Plain text only when there is no HTML.
            if let html = model.detailHTML, !(prefersPlain && hasPlain(detail)) {
                let surface = MailHTMLView.readerSurface(html)
                MailHTMLView(html: html, documentID: message.rowID, loadsRemote: model.loadsImages,
                             zoom: MailReading.clampZoom(zoom), fitsWidth: fitsWidth, scroll: model.readerScroll,
                             surface: surface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A designed message is a light card, inset on the pane. Its own page is not changed.
                    .padding(surface == .card ? MailStyle.cardInset : 0)
            } else {
                // Plain text wraps at a width that reads well, however wide the pane is.
                ScrollView(.vertical) {
                    Text(MailText.linked(detail.readableText)).font(.system(size: MailStyle.body * MailReading.clampZoom(zoom))).lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: MailStyle.readingWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background { MailScrollProbe(scroll: model.readerScroll) }
                }
                .defaultScrollAnchor(.topLeading)
            }
        } else if model.detailMissing {
            MailBodyMissing(model: model)
        } else {
            MailBodyPlaceholder()
        }
    }

    private func hasPlain(_ detail: MIMEMessage) -> Bool {
        !(detail.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
