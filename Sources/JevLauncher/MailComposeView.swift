import SwiftUI
import LauncherCore

/// Writing a reply, forward, or new message. In the launcher panel it sits under the message it
/// answers (`docked`); in the mail window it is a sheet. Send looks dimmed until the draft can
/// go; pressing it then says what is missing.
struct ComposeView: View {
    @ObservedObject var model: MailModel
    var docked = false
    @Environment(\.dismiss) private var dismiss
    /// A reply starts in its text, so typing goes there and not to a search or filter field.
    @FocusState private var bodyFocused: Bool
    @FocusState private var toFocused: Bool

    /// Labels and the title's symbol sit in this column; titles, values, and the Quill field line up after it.
    private static let labelWidth: CGFloat = 52
    private static let gutter: CGFloat = 14

    var body: some View {
        if let binding = Binding($model.draft) {
            let draft = binding.wrappedValue
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header(draft, binding)
                    if model.canUseQuill { Divider().padding(.leading, Self.gutter); quill(binding) }
                }
                // A light band, so the composer's top reads apart from the message above it.
                .background(Color.primary.opacity(0.05))
                Divider()
                editor(binding)
                Divider()
                footer(draft)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .frame(width: docked ? nil : 600, height: docked ? nil : 460)
            .onAppear {
                // A reply starts in its text; a new message or a forward starts in To.
                let reply = { if case .reply = draft.mode { return true }; return false }()
                DispatchQueue.main.async { if reply { bodyFocused = true } else { toFocused = true } }
            }
        }
    }

    // MARK: Parts

    private func header(_ draft: MailModel.Draft, _ binding: Binding<MailModel.Draft>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(symbol: symbol(draft.mode)) {
                Text(title(draft)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            Divider().padding(.leading, Self.gutter)
            switch draft.mode {
            case .reply:
                let line = draft.replyLine
                row("To") {
                    Text(line?.text ?? draft.to).lineLimit(1).truncationMode(.tail)
                        .help((line?.detail ?? draft.to) + "\n" + recipientsNote)
                }
            case .forward:
                row("To") { field("Addresses, separated by commas", text: binding.to).focused($toFocused) }
            case .new:
                row("To") { field("Addresses, separated by commas", text: binding.to).focused($toFocused) }
                Divider().padding(.leading, Self.gutter)
                row("Cc") { field("", text: binding.cc) }
                Divider().padding(.leading, Self.gutter)
                row("Subject") { field("", text: binding.subject) }
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
        .padding(.horizontal, Self.gutter).padding(.vertical, 7)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.plain)
    }

    private func quill(_ binding: Binding<MailModel.Draft>) -> some View {
        row(symbol: "sparkles") {
            TextField("", text: binding.instruction, prompt: Text("Tell Quill what to write, such as “yes, but next week”"))
                .textFieldStyle(.plain).onSubmit { model.draftWithQuill() }
            Button(model.quillBusy ? "Writing…" : "Draft with Quill") { model.draftWithQuill() }
                .controlSize(.small).disabled(model.quillBusy)
        }
    }

    private func editor(_ binding: Binding<MailModel.Draft>) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: binding.body)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($bodyFocused)
                .padding(.horizontal, 9).padding(.vertical, 8)
            if binding.wrappedValue.body.isEmpty {
                Text(placeholder(binding.wrappedValue.mode)).font(.system(size: 14)).foregroundStyle(.tertiary)
                    .padding(.horizontal, Self.gutter).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 110)
    }

    private func footer(_ draft: MailModel.Draft) -> some View {
        HStack(spacing: 10) {
            // Why Send did nothing, or that Escape again discards, in place of the usual note.
            if let note = model.composeNote {
                Label(note, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let note = note(draft.mode) {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Discard") {
                // The sheet closes with the draft; the panel's docked composer has nothing to dismiss.
                if model.discardDraft(), !docked { dismiss() }
            }
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
            .disabled(model.quillBusy)
            .help(model.quillBusy ? "Wait until Quill finishes writing." : draft.sendProblem ?? "Send (⌘Return). You can undo for 5 seconds.")
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

    /// Who picks the final recipients. Apple Mail uses its own list when it sends.
    private var recipientsNote: String {
        NativeMailCenter.isActive ? "Your own address is left out." : "Apple Mail sets the final list when it sends."
    }

    /// What happens to the original. Apple Mail adds it itself; Jevcast's own accounts quote it.
    private func note(_ mode: MailModel.Draft.Mode) -> String? {
        switch mode {
        case .new: return nil
        case .reply where !NativeMailCenter.isActive: return "Apple Mail sets the final recipients and adds the original below your text."
        default:
            return NativeMailCenter.isActive ? "The original message is quoted below your text."
                : "Apple Mail adds the original message below your text when it can."
        }
    }
}
