import SwiftUI
import LauncherCore

/// Writing a reply, forward, or new message, laid out like Apple Mail's composer: To, Cc, Bcc,
/// Subject, and From, a formatting bar, your text, and below it the original exactly as it is
/// sent. It fills the reading pane in the mail window and in the launcher panel. Send looks
/// dimmed until the draft can go; pressing it then says what is missing.
struct ComposeView: View {
    @ObservedObject var model: MailModel
    /// A reply starts in its text, so typing goes there and not to a search or filter field.
    @FocusState private var bodyFocused: Bool
    @FocusState private var toFocused: Bool
    @StateObject private var editorCommands = MailEditorCommands()
    @State private var showsLink = false
    @State private var link = ""

    /// Labels sit in this column; the fields line up after it.
    private static let labelWidth: CGFloat = 62
    private static let gutter: CGFloat = 14

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
                composeTools(current)
                if let reason = current.serverDraftBlockedReason {
                    MailServerDraftStatusRow(coordinator: model.serverDrafts, draft: current, reason: reason)
                }
                if !current.attachments.isEmpty { attachments(current) }
                Divider()
                content(current, binding)
                Divider()
                footer(current)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $model.showsOutbox) { MailDeliveryView(model: model) }
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
                DispatchQueue.main.async { if reply { bodyFocused = true } else { toFocused = true } }
            }
        }
    }

    private func native(_ draft: MailModel.Draft) -> Bool { draft.backend == MailBackend.jevcast.rawValue }
    private func isReply(_ draft: MailModel.Draft) -> Bool { if case .reply = draft.mode { return true }; return false }

    // MARK: Headers

    private func header(_ draft: MailModel.Draft, _ binding: Binding<MailModel.Draft>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(symbol: symbol(draft.mode)) {
                Text(title(draft)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            Divider().padding(.leading, Self.gutter)
            if isReply(draft) && !native(draft) {
                // Apple Mail picks a reply's recipients and subject itself when it sends.
                let line = draft.replyLine
                row("To:") {
                    Text(line?.text ?? draft.to).lineLimit(1).truncationMode(.tail)
                        .help((line?.detail ?? draft.to) + "\nApple Mail sets the final list when it sends.")
                }
            } else {
                row("To:") { field("Addresses, separated by commas", text: binding.to).focused($toFocused) }
                Divider().padding(.leading, Self.gutter)
                row("Cc:") { field("", text: binding.cc) }
                if native(draft) {
                    Divider().padding(.leading, Self.gutter)
                    row("Bcc:") { field("", text: binding.bcc) }
                }
                if native(draft) || draft.mode == .new {
                    Divider().padding(.leading, Self.gutter)
                    row("Subject:") { field("", text: binding.subject) }
                }
            }
            Divider().padding(.leading, Self.gutter)
            row("From:") {
                Picker("Sending account", selection: Binding(get: {
                    model.senders.first { $0.accountID == draft.fromAccountID && $0.address == draft.fromAddress }?.id ?? ""
                }, set: { model.selectSender($0) })) {
                    if !model.senders.contains(where: { $0.accountID == draft.fromAccountID && $0.address == draft.fromAddress }) {
                        Text("Select an account").tag("")
                    }
                    ForEach(model.senders) { Text($0.title).lineLimit(1).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if native(draft) {
                    Button("Insert Signature") { model.insertSignature() }.buttonStyle(.borderless).font(.system(size: 12))
                        .fixedSize()
                        .help("Adds this account's signature at the end of your text. Set it in Settings › Mail.")
                }
            }
        }
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

    private func aiWritingRow(_ binding: Binding<MailModel.Draft>) -> some View {
        row(symbol: "sparkles") {
            TextField("", text: binding.instruction, prompt: Text("Tell the AI what to write, such as “yes, but next week”"))
                .textFieldStyle(.plain).onSubmit { model.draftWithAI() }
            Button(model.aiWritingBusy ? "Writing…" : "Draft with AI") { model.draftWithAI() }
                .controlSize(.small).disabled(model.aiWritingBusy)
        }
    }

    // MARK: Formatting

    private func composeTools(_ draft: MailModel.Draft) -> some View {
        HStack(spacing: 10) {
            if native(draft) {
                ScrollView(.horizontal, showsIndicators: false) {
                    MailFormattingBar(commands: editorCommands, addLink: { link = ""; showsLink = true },
                                      insertImage: { model.pickAttachments(inline: true) }, attach: { model.pickAttachments() })
                }
            } else {
                Button { model.pickAttachments() } label: { Image(systemName: "paperclip") }.help("Attach files")
            }
            Spacer(minLength: 0)
            Button("Outbox") { model.showsOutbox = true }.font(.caption)
        }
        .buttonStyle(.borderless).padding(.horizontal, Self.gutter).padding(.vertical, 6)
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
            VSplitView {
                editor(binding).frame(minHeight: 90, idealHeight: 170)
                quote(draft, binding).frame(minHeight: 80, maxHeight: .infinity)
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
                MailRichEditor(text: binding.body, rtf: binding.richText, commands: editorCommands, focus: bodyFocused)
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

    @ViewBuilder
    private func quote(_ draft: MailModel.Draft, _ binding: Binding<MailModel.Draft>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(isReply(draft) ? "Quoted below your text, as sent. It cannot be edited." : "Forwarded below your text, as sent.")
                    .foregroundStyle(.secondary)
                Spacer()
                if isReply(draft) {
                    Button("Remove Quote") { binding.wrappedValue.includesQuote = false }.buttonStyle(.link)
                        .help("Send only your text")
                }
            }
            .font(.caption).padding(.horizontal, Self.gutter).padding(.vertical, 5)
            if let source = draft.source, let original = draft.original {
                MailQuotePreview(source: source, date: original.date, forward: !isReply(draft), loadsRemote: model.loadsImages)
            } else {
                Text("Loading the original…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Footer

    private func footer(_ draft: MailModel.Draft) -> some View {
        HStack(spacing: 10) {
            // Why Send did nothing, or that Escape again discards, in place of the usual note.
            if let note = model.composeNote {
                Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let note = note(draft) {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Discard") { model.discardDraft() }
            .keyboardShortcut(.cancelAction)
            .help("Discard (Escape)")
            Button { model.send() } label: {
                HStack(spacing: 6) {
                    Text("Send")
                    Text("⌘↩").opacity(0.7)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            // Enabled but dimmed while something is missing, so pressing it says what.
            .opacity(draft.canSend ? 1 : 0.5)
            .disabled(model.aiWritingBusy)
            .help(model.aiWritingBusy ? "Wait until AI writing finishes." : draft.sendProblem ?? "Send (⌘Return). You can undo for 5 seconds.")
        }
        .controlSize(.regular)
        .padding(.horizontal, Self.gutter).padding(.vertical, 9)
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
