import SwiftUI
import LauncherCore

/// Writing a reply, forward, or new message. In the launcher panel it sits under the message it
/// answers (`docked`); in the mail window it is a sheet. Send stays dimmed until the draft can go.
struct ComposeView: View {
    @ObservedObject var model: MailModel
    var docked = false
    @Environment(\.dismiss) private var dismiss
    /// A reply starts in its text, so typing goes there and not to a search or filter field.
    @FocusState private var bodyFocused: Bool
    @FocusState private var toFocused: Bool

    var body: some View {
        if let binding = Binding($model.draft) {
            let draft = binding.wrappedValue
            VStack(alignment: .leading, spacing: 0) {
                header(draft, binding)
                Divider()
                if model.canUseQuill { quill(binding); Divider() }
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
            HStack(spacing: 8) {
                Image(systemName: symbol(draft.mode)).foregroundStyle(.secondary)
                Text(title(draft.mode)).font(.system(size: 13, weight: .semibold))
                if draft.mode != .new {
                    Text(draft.subject).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider().padding(.leading, 14)
            switch draft.mode {
            case .reply:
                row("To") { Text(model.replySummary(for: draft)).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            case .forward:
                row("To") { field("Addresses, separated by commas", text: binding.to).focused($toFocused) }
            case .new:
                row("To") { field("Addresses, separated by commas", text: binding.to).focused($toFocused) }
                Divider().padding(.leading, 14)
                row("Cc") { field("", text: binding.cc) }
                Divider().padding(.leading, 14)
                row("Subject") { field("", text: binding.subject) }
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.plain)
    }

    private func quill(_ binding: Binding<MailModel.Draft>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            TextField("", text: binding.instruction, prompt: Text("Tell Quill what to write, such as “yes, but next week”"))
                .textFieldStyle(.plain).onSubmit { model.draftWithQuill() }
            Button(model.quillBusy ? "Writing…" : "Draft with Quill") { model.draftWithQuill() }
                .controlSize(.small).disabled(model.quillBusy)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14).padding(.vertical, 7)
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
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 110)
    }

    private func footer(_ draft: MailModel.Draft) -> some View {
        HStack(spacing: 10) {
            if let note = note(draft.mode) { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            Button("Discard") { model.draft = nil; dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("Discard (Escape)")
            Button { model.send() } label: {
                HStack(spacing: 6) {
                    Text(model.sending ? "Sending…" : "Send")
                    Text("⌘↩").opacity(0.7)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.canSend || model.sending)
            .help(draft.sendProblem ?? "Send (⌘Return). Undo is possible for 5 seconds.")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: Words

    private func title(_ mode: MailModel.Draft.Mode) -> String {
        switch mode {
        case .new: return "New Message"
        case .reply(let all): return all ? "Reply All" : "Reply"
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

    /// What happens to the original. Apple Mail adds it itself; Jevcast's own accounts quote it.
    private func note(_ mode: MailModel.Draft.Mode) -> String? {
        guard mode != .new else { return nil }
        return NativeMailCenter.isActive ? "The original message is quoted below your text."
            : "Apple Mail adds the original message below your text when it can."
    }
}
