import SwiftUI
import LauncherCore

/// Writing a reply, forward, or new message, laid out like Apple Mail's composer: To, Cc, Bcc,
/// Subject, and From, your text, and below it the original exactly as it is sent. The header
/// keeps only what you need: From shows when you have more than one account (or with Cc/Bcc),
/// and what you are writing is named in the footer. The formatting bar shows after Aa. It fills
/// the reading pane in the launcher panel. Send looks dimmed until the draft can go; pressing it
/// then says what is missing.
struct ComposeView: View {
    @ObservedObject var model: MailModel
    var schedules: MailScheduleCenter? = nil
    /// Whether the formatting bar shows. The page keeps it, so it stays as you left it.
    @ObservedObject var preferences = MailComposerPreferences(defaults: nil)
    /// A reply starts in its text, so typing goes there and not to a search or filter field.
    @FocusState private var bodyFocused: Bool
    @StateObject private var editorCommands = MailEditorCommands()
    @State private var showsLink = false
    @State private var link = ""
    /// Cc and Bcc show once asked for, or when they hold an address.
    @State private var showsCopies = false
    /// The original stays out of the way until asked for. It is still sent below your text.
    @State private var showsQuote = false
    /// The footer's width. Below `MailComposerFooter.compactWidth`, Send Later shows as its icon.
    @State private var footerWidth: CGFloat = 0

    /// Labels sit in this column; the fields line up after it.
    private static let labelWidth: CGFloat = 62
    private static let gutter: CGFloat = 14
    /// The To field's placeholder: short, so it fits beside Cc/Bcc in the narrowest panel (860).
    static let recipientPlaceholder = "Name or email"

    var body: some View {
        if let current = model.draft {
            // Not `Binding($model.draft)`: that force-unwraps, and the text editor reads the binding
            // once more after Send or Discard sets the draft to nil. A closed draft keeps its last value.
            let binding = Binding<MailModel.Draft>(get: { model.draft ?? current },
                                                   set: { new in if model.draft?.id == current.id { model.draft = new } })
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header(current, binding)
                    if model.canUseAIWriting { Divider().padding(.leading, Self.gutter); aiWritingRow(binding) }
                }
                // A light band, so the headers read apart from the text.
                .background(Color.primary.opacity(0.05))
                Divider()
                if native(current) && preferences.showsFormatting {
                    formattingBar
                        .transition(.opacity)
                    Divider()
                }
                if let reason = current.serverDraftBlockedReason {
                    MailServerDraftStatusRow(coordinator: model.serverDrafts, draft: current, reason: reason)
                    Divider()
                }
                if !current.attachments.isEmpty { attachments(current); Divider() }
                content(current, binding)
                Divider()
                footer(current)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert("Add a Link to Selected Text", isPresented: $showsLink) {
                TextField("https://", text: $link)
                Button("Cancel", role: .cancel) {}
                Button("Add Link") {
                    if let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { editorCommands.link(url) }
                    else { model.composeNote = "Enter an http, https, or mailto link." }
                }
            }
            .onAppear {
                // A reply starts in its text; a new message or a forward starts in To.
                let reply = { if case .reply = current.mode { return true }; return false }()
                if reply { DispatchQueue.main.async { bodyFocused = true } }
            }
        }
    }

    private func native(_ draft: MailModel.Draft) -> Bool { draft.backend == MailBackend.jevcast.rawValue }
    private func isReply(_ draft: MailModel.Draft) -> Bool { if case .reply = draft.mode { return true }; return false }

    // MARK: Headers

    private func header(_ draft: MailModel.Draft, _ binding: Binding<MailModel.Draft>) -> some View {
        let copies = showsCopies || !draft.cc.isEmpty || !draft.bcc.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            if isReply(draft) && !native(draft) {
                // Apple Mail picks a reply's recipients and subject itself when it sends.
                let line = draft.replyLine
                row("To:") {
                    Text(line?.text ?? draft.to).lineLimit(1).truncationMode(.tail)
                        .help((line?.detail ?? draft.to) + "\nApple Mail sets the final list when it sends.")
                }
            } else {
                row("To:") {
                    recipientField(value: binding.to, placeholder: Self.recipientPlaceholder)
                    if !copies {
                        Button(native(draft) ? "Cc/Bcc" : "Cc") { showsCopies = true }.buttonStyle(.borderless).font(.system(size: 12))
                            .fixedSize().help(model.senders.count > 1 ? "Add people in copy" : "Add people in copy, or see the sending account")
                    }
                }
                if copies {
                    Divider().padding(.leading, Self.gutter)
                    row("Cc:") { recipientField(value: binding.cc, placeholder: "Optional") }
                    if native(draft) {
                        Divider().padding(.leading, Self.gutter)
                        row("Bcc:") { recipientField(value: binding.bcc, placeholder: "Optional") }
                    }
                }
                if native(draft) || draft.mode == .new {
                    Divider().padding(.leading, Self.gutter)
                    row("Subject:") { field("", text: binding.subject) }
                }
            }
            if Self.showsFrom(senders: model.senders.count, copies: copies, hasSender: hasSender(draft)) {
                Divider().padding(.leading, Self.gutter)
                row("From:") { MailComposeFromMenu(model: model, draft: draft) }
            }
        }
    }

    /// From shows with more than one account to choose from, with Cc and Bcc, or when the draft
    /// has no account yet. With one account it is the only choice, so it stays out of the way.
    static func showsFrom(senders: Int, copies: Bool, hasSender: Bool) -> Bool {
        senders > 1 || copies || !hasSender
    }

    private func hasSender(_ draft: MailModel.Draft) -> Bool {
        model.senders.contains { $0.accountID == draft.fromAccountID && $0.address == draft.fromAddress }
    }

    private func row<Content: View>(_ label: String = "", symbol: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(label) }
            }
            .foregroundStyle(.secondary).frame(width: Self.labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, Self.gutter).padding(.vertical, 6)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.plain)
    }

    private func recipientField(value: Binding<String>, placeholder: String) -> some View {
        MailRecipientChipField(placeholder, value: value,
                               suggestions: { model.recipientSuggestions(for: $0) },
                               requestContacts: { query in
                                   await MailContactsSuggestionSource.requestAndSuggest(query: query)
                               })
    }

    private func aiWritingRow(_ binding: Binding<MailModel.Draft>) -> some View {
        row(symbol: "sparkles") {
            TextField("", text: binding.instruction, prompt: Text("Tell the AI what to write, such as “yes, but next week”"))
                .textFieldStyle(.plain).onSubmit { model.draftWithAI() }
            Button(model.aiWritingBusy ? "Writing…" : "Draft with AI") { model.draftWithAI() }
                .controlSize(.small).disabled(model.aiWritingBusy)
        }
    }

    // MARK: Formatting

    /// Font, size, colour, styles, alignment, lists, link, and image. Attach is in the footer.
    private var formattingBar: some View {
        MailFormattingBar(commands: editorCommands, addLink: { link = ""; showsLink = true },
                          insertImage: { model.pickAttachments(inline: true) })
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.gutter).padding(.vertical, 6)
    }

    private func attachments(_ draft: MailModel.Draft) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(draft.attachments.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: 4) {
                        Image(systemName: file.contentID == nil ? "doc" : "photo")
                        Text(file.filename).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)).foregroundStyle(.secondary)
                        Button { model.draft?.attachments.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }.font(.caption).padding(6).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.padding(.horizontal, Self.gutter).padding(.vertical, 6)
    }

    // MARK: Text and quote

    /// Your text, and for Jevcast's own accounts the original below it, as it is sent.
    @ViewBuilder
    private func content(_ draft: MailModel.Draft, _ binding: Binding<MailModel.Draft>) -> some View {
        if native(draft), draft.mode != .new, draft.includesQuote || !isReply(draft) {
            if showsQuote {
                VSplitView {
                    editor(binding).frame(minHeight: 90, idealHeight: 170)
                    quote(draft, binding).frame(minHeight: 80, maxHeight: .infinity)
                }
            } else {
                // Your text has the whole pane. One line says the original goes with it.
                VStack(spacing: 0) {
                    editor(binding)
                    Divider()
                    quoteBar(draft, binding)
                }
            }
        } else {
            VStack(spacing: 0) {
                editor(binding)
                if native(draft), isReply(draft) {
                    Divider()
                    HStack {
                        Text("The original is left out.").foregroundStyle(.secondary)
                        Button("Include Original") { binding.wrappedValue.includesQuote = true }.buttonStyle(.link)
                        Spacer()
                    }.font(.caption).padding(.horizontal, Self.gutter).padding(.vertical, 6)
                }
            }
        }
    }

    private func editor(_ binding: Binding<MailModel.Draft>) -> some View {
        ZStack(alignment: .topLeading) {
            if native(binding.wrappedValue) {
                MailRichEditor(text: binding.body, rtf: binding.richText, commands: editorCommands, focus: bodyFocused,
                               cursor: MailSignatureText.cursor(in: binding.wrappedValue.body, signature: binding.wrappedValue.automaticSignature))
            } else {
                TextEditor(text: binding.body)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($bodyFocused)
                .padding(.horizontal, 9).padding(.vertical, 8)
            }
            if binding.wrappedValue.body.isEmpty {
                Text(placeholder(binding.wrappedValue.mode)).font(.system(size: 14)).foregroundStyle(.tertiary)
                    .padding(.horizontal, Self.gutter).padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One line about the original: that it is sent, a way to see it, and for a reply a way to leave it out.
    private func quoteBar(_ draft: MailModel.Draft, _ binding: Binding<MailModel.Draft>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "text.quote").foregroundStyle(.tertiary)
            Text(isReply(draft) ? "The original is quoted below your text, as sent." : "The original is forwarded below your text, as sent.")
                .foregroundStyle(.secondary)
            Spacer()
            Button(showsQuote ? "Hide Original" : "Show Original") { showsQuote.toggle() }.buttonStyle(.link)
            if isReply(draft) {
                Button("Remove Quote") { binding.wrappedValue.includesQuote = false }.buttonStyle(.link)
                    .help("Send only your text")
            }
        }
        .font(.caption).padding(.horizontal, Self.gutter).padding(.vertical, 6)
    }

    @ViewBuilder
    private func quote(_ draft: MailModel.Draft, _ binding: Binding<MailModel.Draft>) -> some View {
        VStack(spacing: 0) {
            quoteBar(draft, binding)
            if let source = draft.source, let original = draft.original {
                MailQuotePreview(source: source, date: original.date, forward: !isReply(draft), loadsRemote: model.loadsImages)
            } else {
                Text("Loading the original…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Footer

    /// In a narrow pane what you are writing gives way first, then Send Later shows as its icon.
    /// Send and Discard keep their whole names.
    private func footer(_ draft: MailModel.Draft) -> some View {
        HStack(spacing: 10) {
            // Why Send did nothing, or that Discard again discards, in place of what you are writing.
            Group {
                if let note = model.composeNote {
                    Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(title(draft), systemImage: symbol(draft.mode))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .help(title(draft))
                        if let note = note(draft) { Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1).help(note) }
                    }
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { model.pickAttachments() } label: { Image(systemName: "paperclip") }
                    .help("Attach files (⇧⌘A)").accessibilityLabel("Attach Files")
                if native(draft) { formattingToggle }
            }
            .buttonStyle(MailIconButtonStyle()).foregroundStyle(.secondary)
            if let schedules, native(draft), let id = draft.fromAccountID, let address = draft.fromAddress {
                MailScheduleButton(draft: draft, account: .init(accountID: id, address: address), center: schedules) { entry in
                    model.didSchedule(entry)
                }
                .labelStyle(MailComposerFooter.compact(footerWidth) ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .fixedSize()
                .disabled(model.aiWritingBusy || !draft.canSend)
            }
            // Quiet beside Send, so the two are never mistaken for each other. Escape never
            // discards: it closes the composer and keeps the draft. The panel handles ⇧⌘⌫.
            Button("Discard") { model.discardDraft() }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .fixedSize()
            .help("Discard (⇧⌘⌫)")
            Button { model.send() } label: {
                HStack(spacing: 6) {
                    Text("Send")
                    Text("⌘↩").opacity(0.7)
                }
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .keyboardShortcut(.return, modifiers: .command)
            // Enabled but dimmed while something is missing, so pressing it says what.
            .opacity(draft.canSend ? 1 : 0.5)
            .disabled(model.aiWritingBusy)
            .help(model.aiWritingBusy ? "Wait until AI writing finishes." : draft.sendProblem ?? "Send (⌘Return). You can undo for 5 seconds.")
        }
        .controlSize(.regular)
        .padding(.horizontal, Self.gutter).padding(.vertical, 9)
        .background { GeometryReader { geo in Color.clear.onAppear { footerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in footerWidth = width } } }
    }

    /// Aa shows or hides the formatting bar. The keys (⌘B, ⌘I, ⌘U) work either way.
    private var formattingToggle: some View {
        let on = preferences.showsFormatting
        return Button { withAnimation(MailStyle.motion) { preferences.showsFormatting.toggle() } } label: {
            Text("Aa").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(minWidth: 18)
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.accentColor.opacity(0.15) : Color.clear))
        .help(on ? "Hide formatting" : "Show formatting")
        .accessibilityLabel("Formatting")
        .accessibilityValue(on ? "Shown" : "Hidden")
    }

    // MARK: Words

    private func title(_ draft: MailModel.Draft) -> String {
        switch draft.mode {
        case .new: return "New Message"
        case .reply(let all):
            guard let sender = draft.original?.sender, !sender.isEmpty else { return all ? "Reply All" : "Reply" }
            return (all ? "Reply All to " : "Reply to ") + sender
        case .forward: return "Forward"
        }
    }

    private func symbol(_ mode: MailModel.Draft.Mode) -> String {
        switch mode {
        case .new: return "square.and.pencil"
        case .reply(let all): return all ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left"
        case .forward: return "arrowshape.turn.up.right"
        }
    }

    private func placeholder(_ mode: MailModel.Draft.Mode) -> String {
        switch mode {
        case .new: return "Write your message"
        case .reply: return "Write your reply"
        case .forward: return "Add a note (optional)"
        }
    }

    /// What happens to the original with Apple Mail, which adds it itself. Jevcast's own accounts show it.
    private func note(_ draft: MailModel.Draft) -> String? {
        guard !native(draft), draft.mode != .new else { return nil }
        if isReply(draft) { return "Apple Mail sets the final recipients and adds the original below your text." }
        return "Apple Mail adds the original message below your text when it can."
    }
}

/// The original under a reply or forward, built exactly as it is sent and shown read only. It is
/// built once per message, off the main thread, so typing never rebuilds a large HTML email.
struct MailQuotePreview: View {
    let source: MailModel.Draft.Source
    let date: Date
    let forward: Bool
    let loadsRemote: Bool
    @State private var html: String?

    var body: some View {
        Group {
            if let html {
                MailHTMLView(html: html, documentID: source.rowID, inlineImages: source.message.inlineImages, loadsRemote: loadsRemote)
            } else {
                Color.clear
            }
        }
        .task(id: "\(source.rowID)-\(forward)") {
            let message = source.message, date = date, forward = forward
            html = await Task.detached(priority: .userInitiated) {
                forward ? MailHTML.forwarded(message, date: MailReplies.attribution(date))
                    : MailHTML.quoted(message, attribution: MailReplies.replyAttribution(date: date, sender: message.header("From") ?? ""))
            }.value
        }
    }
}

/// The composer footer's layout rule.
enum MailComposerFooter {
    /// Below this width, Send Later shows as its icon with its name in the tooltip.
    static let compactWidth: CGFloat = 520

    /// True when the footer is too narrow for Send Later's name. Zero means not measured yet.
    static func compact(_ width: CGFloat) -> Bool { width > 0 && width < compactWidth }
}

/// One of two label styles, chosen while the view runs.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<Style: LabelStyle>(_ style: Style) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
