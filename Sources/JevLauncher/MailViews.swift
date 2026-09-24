import SwiftUI
import LauncherCore

/// The mail window: every inbox in one list, and the message beside it. Built for checking mail:
/// ↑↓ or J K move, ⌫ deletes, E archives, R replies, U marks unread, C writes a new message.
struct MailRootView: View {
    @ObservedObject var model: MailModel

    var body: some View {
        Group {
            switch model.status {
            case .ready: split
            case .needsFullDiskAccess: MailSetupView(model: model, needsAccess: true)
            case .noMail: MailSetupView(model: model, needsAccess: false)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(item: Binding(get: { model.draft.map { DraftBox(draft: $0) } }, set: { if $0 == nil { model.draft = nil } })) { _ in
            ComposeView(model: model)
        }
    }

    private var split: some View {
        HSplitView {
            MailList(model: model).frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
            MailReader(model: model).frame(minWidth: 380, maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                Text(banner).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 14)
                    .onTapGesture { model.banner = nil }
                    .task(id: banner) { try? await Task.sleep(nanoseconds: 4_000_000_000); if model.banner == banner { model.banner = nil } }
            }
        }
    }
}

private struct DraftBox: Identifiable { let draft: MailModel.Draft; var id: String { "draft" } }

struct MailSetupView: View {
    @ObservedObject var model: MailModel
    let needsAccess: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: needsAccess ? "lock.shield" : "envelope").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(needsAccess ? "Allow Jevcast to read Mail" : "Set up Apple Mail first").font(.title2.weight(.semibold))
            if needsAccess {
                Text("macOS protects Apple Mail's messages. Full Disk Access does not list apps by itself, so add Jevcast once:")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click Open Full Disk Access.")
                    Text("2. Click + below the list, choose Jevcast in Applications, and click Open. Or drag Jevcast from the Finder window into the list.")
                    Text("3. Make sure the Jevcast switch is on.")
                    Text("4. Click Restart Jevcast. macOS applies the access only to a new start.")
                }
                .font(.callout).frame(maxWidth: 460, alignment: .leading)
                Text("Nothing leaves your Mac unless you use Luna on a message.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Full Disk Access") { Permissions.open("Privacy_AllFiles") }
                    Button("Show Jevcast in Finder") { Frontmost.reveal([Bundle.main.bundleURL]) }
                    Button("Restart Jevcast") { Relaunch.now() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Jevcast shows the accounts you add to Apple Mail. Add an account in Mail, then check again.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                Button("Check Again") { model.refreshStatus() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MailList: View {
    @ObservedObject var model: MailModel
    @FocusState private var listFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $model.selectedID) {
                ForEach(model.messages) { message in
                    MailRow(message: message, delete: { model.delete(message.rowID) }).tag(message.rowID)
                }
            }
            .listStyle(.inset)
            .focused($listFocused)
            .overlay { if model.messages.isEmpty { Text(model.search.isEmpty ? "Inbox is empty" : "No matches").foregroundStyle(.secondary) } }
        }
        .onAppear { listFocused = true }
        .onKeyPress(characters: .letters.union(CharacterSet(charactersIn: "#")), phases: .down) { press in
            // ⌘E, ⌃S, and other shortcuts are not mail keys.
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            return handle(press.characters, shift: press.modifiers.contains(.shift)) ? .handled : .ignored
        }
        .onKeyPress(.delete) { model.delete(); return .handled }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Inbox").font(.title3.weight(.semibold))
                if model.unreadInInbox > 0 { Text("\(model.unreadInInbox) unread").foregroundStyle(.secondary) }
                Spacer()
                Button { model.checkMail() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Check for new mail")
                Button { model.compose() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless)
                    .keyboardShortcut("n").help("New message (⌘N)")
            }
            TextField("Search", text: $model.search).textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    private func handle(_ key: String, shift: Bool) -> Bool {
        switch key.lowercased() {
        case "j": model.moveSelection(1)
        case "k": model.moveSelection(-1)
        case "e": model.archive()
        case "#": model.delete()
        case "r": model.reply(all: shift)
        case "f": model.forward()
        case "s": model.toggleFlag()
        case "u": model.toggleRead()
        case "c": model.compose()
        default: return false
        }
        return true
    }
}

/// Sender, subject, and date: no preview, so the inbox reads at a glance. Hovering shows Delete.
struct MailRow: View {
    let message: MailSummary
    var delete: () -> Void = {}
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle().fill(message.read ? Color.clear : Color.accentColor).frame(width: 7, height: 7)
                .accessibilityLabel(message.read ? "" : "Unread")
            VStack(alignment: .leading, spacing: 1) {
                Text(message.sender).font(.system(size: 13, weight: message.read ? .regular : .semibold)).lineLimit(1)
                Text(message.subject.isEmpty ? "No subject" : message.subject).font(.system(size: 12))
                    .foregroundStyle(message.read ? .secondary : .primary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if message.flagged { Image(systemName: "flag.fill").foregroundStyle(.orange).font(.caption) }
            if hovering {
                Button(action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete (⌫)")
            } else {
                Text(Self.date(message.date)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { Button("Delete", role: .destructive, action: delete) }
    }
    static func date(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(date: .numeric, time: .omitted)
    }
}

struct MailReader: View {
    @ObservedObject var model: MailModel
    var body: some View {
        if let message = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                actionBar
                Divider()
                header(message)
                Divider()
                if let summary = model.summary {
                    GroupBox { Text(summary).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        label: { Label("Luna summary", systemImage: "sparkles") }
                        .padding(12)
                }
                body(message)
            }
        } else {
            Text("Select a message").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ message: MailSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.subject.isEmpty ? "No subject" : message.subject).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 4) {
                Text(message.sender).fontWeight(.medium)
                if !message.senderName.isEmpty { Text("<\(message.senderAddress)>").foregroundStyle(.secondary) }
                Spacer()
                Text(message.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).textSelection(.enabled)
            if let to = model.detail?.header("To") { Text("To: " + to).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let cc = model.detail?.header("Cc") { Text("Cc: " + cc).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let attachments = model.detail?.attachments, !attachments.isEmpty {
                HStack {
                    Image(systemName: "paperclip")
                    Text(attachments.map(\.name).joined(separator: ", ")).lineLimit(1)
                    Button("Open in Mail") { model.openInMail() }.controlSize(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    @ViewBuilder private func body(_ message: MailSummary) -> some View {
        if let detail = model.detail {
            if let html = detail.html, detail.plainText == nil || html.utf8.count > 200 {
                MailHTMLView(html: html).padding(.horizontal, 10)
            } else {
                ScrollView {
                    Text(detail.readableText).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            }
        } else if model.detailMissing {
            VStack(spacing: 8) {
                Text("Mail has not downloaded this message yet.").foregroundStyle(.secondary)
                Button("Open in Mail") { model.openInMail() }
            }
            .padding(14)
            Spacer()
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The actions for checking mail, always visible.
    private var actionBar: some View {
        HStack(spacing: 14) {
            Button { model.delete() } label: { Label("Delete", systemImage: "trash") }.help("Delete (⌫)")
            Button { model.archive() } label: { Label("Archive", systemImage: "archivebox") }.help("Archive (E)")
            Button { model.reply(all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }.help("Reply (R)")
            Button { model.toggleRead() } label: {
                Label(model.selected?.read == false ? "Mark Read" : "Mark Unread", systemImage: "envelope.badge")
            }.help("Read or unread (U)")
            Spacer()
            if model.canUseLuna {
                Button { model.summarise() } label: { Label("Summarise", systemImage: "sparkles") }
                    .disabled(model.detail == nil || model.lunaBusy).help("Summarise with Luna")
            }
            Button { model.openInMail() } label: { Label("Open in Mail", systemImage: "arrow.up.forward.app") }.help("Open this message in Apple Mail")
        }
        .buttonStyle(.borderless).labelStyle(.titleAndIcon).font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

struct ComposeView: View {
    @ObservedObject var model: MailModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let binding = Binding($model.draft) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title(binding.wrappedValue.mode)).font(.headline)
                if binding.wrappedValue.mode == .new || binding.wrappedValue.mode == .forward {
                    TextField("To", text: binding.to).textFieldStyle(.roundedBorder)
                }
                if binding.wrappedValue.mode == .new {
                    TextField("Cc", text: binding.cc).textFieldStyle(.roundedBorder)
                    TextField("Subject", text: binding.subject).textFieldStyle(.roundedBorder)
                } else {
                    Text(binding.wrappedValue.subject).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.canUseLuna {
                    HStack {
                        TextField("Tell Luna what to write, such as “yes, but next week”", text: binding.instruction)
                            .textFieldStyle(.roundedBorder).onSubmit { model.draftWithLuna() }
                        Button(model.lunaBusy ? "Writing…" : "Draft with Luna") { model.draftWithLuna() }.disabled(model.lunaBusy)
                    }
                }
                TextEditor(text: binding.body).font(.system(size: 13)).frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if binding.wrappedValue.mode != .new {
                    Text("Mail adds the original message below your text when it can.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.draft = nil; dismiss() }.keyboardShortcut(.cancelAction)
                    Button(model.sending ? "Sending…" : "Send") { model.send() }
                        .keyboardShortcut(.return, modifiers: .command).disabled(model.sending)
                }
            }
            .padding(18)
            .frame(width: 560)
        }
    }
    private func title(_ mode: MailModel.Draft.Mode) -> String {
        switch mode {
        case .new: return "New Message"
        case .reply(let all): return all ? "Reply All" : "Reply"
        case .forward: return "Forward"
        }
    }
}
