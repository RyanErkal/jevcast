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
            Text(needsAccess ? "Allow Jevcast to read Mail" : NativeMailCenter.isActive ? "Add a mail account" : "Set up Apple Mail first").font(.title2.weight(.semibold))
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
                Text("Nothing leaves your Mac unless you use Quill on a message.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Full Disk Access") { Permissions.open("Privacy_AllFiles") }
                    Button("Show Jevcast in Finder") { Frontmost.reveal([Bundle.main.bundleURL]) }
                    Button("Restart Jevcast") { Relaunch.now() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(NativeMailCenter.isActive ? "Jevcast syncs the accounts you add in Settings › Mail. Add one there, then check again."
                     : "Jevcast shows the accounts you add to Apple Mail. Add an account in Mail, then check again.")
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
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MailMessageList(model: model)
        }
        .onChange(of: model.searching) { _, on in searchFocused = on }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MailPlacePicker(model: model).font(.headline)
                if model.unreadInInbox > 0 { Text("\(model.unreadInInbox) unread").foregroundStyle(.secondary) }
                Spacer()
                Button { model.searching.toggle() } label: { Image(systemName: "magnifyingglass") }.help("Search (⌘F)")
                Button { model.checkMail() } label: { Image(systemName: "arrow.clockwise") }.help("Check for new mail")
                Button { model.compose() } label: { Image(systemName: "square.and.pencil") }.help("New message (⌘N)")
            }
            .buttonStyle(.borderless)
            MailClosedNote(model: model)
            if model.searching {
                TextField("Search senders, subjects, and text", text: $model.search)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .onSubmit { model.searching = !model.search.isEmpty }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// Sender, subject, and date: no preview, so the inbox reads at a glance. Hovering shows Delete.
/// Rows compare by message only, so a list update redraws just the rows that changed.
struct MailRow: View, Equatable {
    static func == (a: MailRow, b: MailRow) -> Bool { a.message == b.message }
    let message: MailSummary
    var delete: () -> Void = {}
    var deleteAll: () -> Void = {}
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
        .contextMenu {
            Button("Delete", role: .destructive, action: delete)
            Button("Delete All from \(message.sender)", role: .destructive, action: deleteAll)
        }
    }
    static func date(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(date: .numeric, time: .omitted)
    }
}

struct MailReader: View {
    @ObservedObject var model: MailModel
    /// Set in the launcher panel: shows an Expand button that hides the list.
    var expanded: Binding<Bool>? = nil
    @AppStorage(MailReading.zoomKey) private var zoom = 1.0
    @AppStorage(MailReading.fitKey) private var fitsWidth = true
    @AppStorage(MailReading.plainKey) private var prefersPlain = false
    var body: some View {
        if let message = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                actionBar
                Divider()
                header(message)
                Divider()
                if let summary = model.summary {
                    GroupBox { Text(summary).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        label: { Label("Quill summary", systemImage: "sparkles") }
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
            // The message as the sender styled it, with its images. Plain text only when there is no HTML.
            if let html = model.detailHTML, !(prefersPlain && hasPlain(detail)) {
                MailHTMLView(html: html, documentID: message.rowID, loadsRemote: model.loadsImages,
                             zoom: MailReading.clampZoom(zoom), fitsWidth: fitsWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(MailText.linked(detail.readableText)).font(.system(size: 13 * MailReading.clampZoom(zoom))).textSelection(.enabled)
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

    private func hasPlain(_ detail: MIMEMessage) -> Bool {
        !(detail.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var zoomControl: some View {
        HStack(spacing: 6) {
            Button { zoom = MailReading.clampZoom(zoom - 0.25) } label: { Image(systemName: "textformat.size.smaller") }
                .help("Smaller text").disabled(zoom <= MailReading.zoomRange.lowerBound)
            Text("\(Int((MailReading.clampZoom(zoom) * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 34)
            Button { zoom = MailReading.clampZoom(zoom + 0.25) } label: { Image(systemName: "textformat.size.larger") }
                .help("Larger text").disabled(zoom >= MailReading.zoomRange.upperBound)
        }
    }

    /// The few actions checking mail needs, as icons with their keys in the tooltips.
    private var actionBar: some View {
        HStack(spacing: 16) {
            Button { model.delete() } label: { Image(systemName: "trash") }.help("Delete (⌫)")
            Button { model.archive() } label: { Image(systemName: "archivebox") }.help("Archive (E)")
            Button { model.reply(all: false) } label: { Image(systemName: "arrowshape.turn.up.left") }.help("Reply (R)")
            Button { model.toggleRead() } label: { Image(systemName: model.selected?.read == false ? "envelope.open" : "envelope.badge") }
                .help("Mark read or unread (U)")
            Menu {
                Button("Delete All from \(model.selected?.sender ?? "Sender")", role: .destructive) { model.deleteAllFromSender() }
                if model.canUseQuill { Button("Summarise with Quill") { model.summarise() }.disabled(model.detail == nil || model.quillBusy) }
                Toggle("Load Images from the Web", isOn: $model.loadsImages)
                Toggle("Fit Wide Mail to Width", isOn: $fitsWidth)
                Toggle("Prefer Plain Text", isOn: $prefersPlain)
                Button("Open in Mail (Return)") { model.openInMail() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuIndicator(.hidden).fixedSize()
            Spacer()
            zoomControl
            if let expanded {
                Button { expanded.wrappedValue.toggle() } label: {
                    Image(systemName: expanded.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(expanded.wrappedValue ? "Show the list (Escape)" : "Expand (Space)")
            }
            if let date = model.selected?.date { Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
        }
        .buttonStyle(.borderless).font(.system(size: 14))
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct ComposeView: View {
    @ObservedObject var model: MailModel
    @Environment(\.dismiss) private var dismiss
    /// A reply starts in its text, so typing goes there and not to a search or filter field.
    @FocusState private var bodyFocused: Bool
    @FocusState private var toFocused: Bool
    var body: some View {
        if let binding = Binding($model.draft) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title(binding.wrappedValue.mode)).font(.headline)
                if binding.wrappedValue.mode == .new || binding.wrappedValue.mode == .forward {
                    TextField("To", text: binding.to).textFieldStyle(.roundedBorder).focused($toFocused)
                }
                if binding.wrappedValue.mode == .new {
                    TextField("Cc", text: binding.cc).textFieldStyle(.roundedBorder)
                    TextField("Subject", text: binding.subject).textFieldStyle(.roundedBorder)
                } else {
                    Text(binding.wrappedValue.subject).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.canUseQuill {
                    HStack {
                        TextField("Tell Quill what to write, such as “yes, but next week”", text: binding.instruction)
                            .textFieldStyle(.roundedBorder).onSubmit { model.draftWithQuill() }
                        Button(model.quillBusy ? "Writing…" : "Draft with Quill") { model.draftWithQuill() }.disabled(model.quillBusy)
                    }
                }
                TextEditor(text: binding.body).font(.system(size: 13)).frame(minHeight: 220).focused($bodyFocused)
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
            .onAppear {
                // A reply starts in its text; a new message or a forward starts in To.
                let reply = { if case .reply = binding.wrappedValue.mode { return true }; return false }()
                DispatchQueue.main.async { if reply { bodyFocused = true } else { toFocused = true } }
            }
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
