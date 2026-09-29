import Foundation
import LauncherCore

/// Writing and sending. One draft is open at a time, and a draft with text is never replaced.
/// A sent draft waits for Undo, then goes to Mail after any earlier send. A draft that did not go
/// comes back, or waits in `unsent` while another draft is open.
extension MailModel {
    // MARK: Starting a draft

    func compose(to address: String = "") { startDraft(Draft(to: address)) }

    func reply(all: Bool) {
        guard let message = selected else { return }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: " + message.subject
        startDraft(Draft(mode: .reply(all: all), to: message.senderAddress, subject: subject, original: message, source: loadedSource(message)))
    }

    func forward() {
        guard let message = selected else { return }
        let subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: " + message.subject
        startDraft(Draft(mode: .forward, subject: subject, original: message, source: loadedSource(message)))
    }

    /// Opens `new` in the composer. An open draft with text stays: a view that hid it shows it
    /// again, with a note. A message still in its undo time goes to Mail now.
    @discardableResult
    func startDraft(_ new: Draft) -> Bool {
        if let draft, draft.id != new.id, draft.hasContent {
            banner = "Finish or discard your open \(draft.noun) first."
            draftNudge += 1
            return false
        }
        sendPendingNow()
        draft = new
        return true
    }

    /// The selected message's text, when it is `message` and has loaded.
    private func loadedSource(_ message: MailSummary) -> Draft.Source? {
        guard selectedID == message.rowID, let detail else { return nil }
        return Draft.Source(rowID: message.rowID, message: detail, html: detailHTML)
    }

    /// Keeps the answered message's text with its draft once it loads, such as after a quick R.
    func captureSource(_ rowID: Int64) {
        guard let draft, draft.source == nil, draft.original?.rowID == rowID, let message = draft.original,
              let source = loadedSource(message) else { return }
        self.draft?.source = source
    }

    /// Escape or Discard. A draft with text needs a second press, and the footer says so.
    /// Returns true when the draft closed.
    @discardableResult
    func discardDraft() -> Bool {
        guard let draft else { return true }
        if draft.hasContent, !discardArmed {
            discardArmed = true
            composeNote = "Press Escape or click Discard again to discard this \(draft.noun)."
            return false
        }
        self.draft = nil
        return true
    }

    /// Brings back the oldest draft that did not go, unless a draft with text is open.
    func showUnsent() {
        guard let first = unsent.first, startDraft(first.draft) else { return }
        unsent.removeAll { $0.id == first.id }
    }

    // MARK: Sending

    /// Checks the draft, then sends it after the undo time. The draft leaves the screen at once.
    /// Returns why nothing was sent; the composer's footer shows it.
    @discardableResult
    func send() -> String? {
        guard let draft else { return nil }
        if let problem = refusal(draft) {
            composeNote = problem
            return problem
        }
        // A message still in its undo time goes first.
        sendPendingNow()
        queue(draft, box: draft.original.flatMap(actionBox))
        self.draft = nil
        banner = nil
        return nil
    }

    private func refusal(_ draft: Draft) -> String? {
        if quillBusy { return "Wait until Quill finishes writing." }
        if let problem = draft.sendProblem { return problem }
        if draft.mode != .new, draft.original.flatMap(actionBox) == nil { return "The message to answer is no longer in the list." }
        return nil
    }

    /// Waits for the undo time, then for any earlier send, then sends. Undo takes it back while it waits.
    private func queue(_ draft: Draft, box: MailMailbox?) {
        let ticket = UUID(), delay = undoDelay, action = sendDraft
        pendingSend = draft; pendingTicket = ticket
        sendsAt = Date().addingTimeInterval(delay)
        sendsInFlight += 1
        let timer = Task { if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } }
        undoTimer = timer
        let previous = sendTask
        sendTask = Task { @MainActor [weak self] in
            await timer.value
            guard let self else { return }
            if self.pendingTicket == ticket { self.pendingSend = nil; self.pendingTicket = nil; self.sendsAt = nil; self.undoTimer = nil }
            // Undone. It still waits for earlier sends, so waiting for the last send waits for all.
            if self.undoneSends.remove(ticket) != nil { await previous?.value; return }
            await previous?.value
            do {
                try await action(draft, box)
                self.banner = "Sent."
            } catch {
                self.sendFailed(draft, error)
            }
            self.sendsInFlight -= 1
        }
    }

    /// Ends the undo time of a waiting message, so it goes to Mail now.
    func sendPendingNow() {
        guard pendingSend != nil else { return }
        pendingSend = nil; pendingTicket = nil; sendsAt = nil
        undoTimer?.cancel(); undoTimer = nil
    }

    /// True while a message waits for Undo or is on its way to Mail.
    var sending: Bool { sendsInFlight > 0 }

    /// For quitting: sends a waiting message now and returns when every send is done.
    func finishSends() async {
        sendPendingNow()
        await sendTask?.value
    }

    /// Stops a send during its undo time. The draft comes back, or waits in `unsent` while
    /// another draft with text is open.
    func undoSend() {
        guard let pending = pendingSend, let ticket = pendingTicket else { return }
        pendingSend = nil; pendingTicket = nil; sendsAt = nil
        undoneSends.insert(ticket)
        sendsInFlight -= 1
        undoTimer?.cancel(); undoTimer = nil
        if restore(pending) { banner = "Not sent. Your message is back." }
        else { unsent.append(Unsent(draft: pending, reason: "Not sent. Your message is kept.")) }
    }

    /// Nothing typed is lost: the draft comes back with the reason, or waits in `unsent`. When Mail
    /// may have sent it, the note says to check Sent instead of "Not sent".
    private func sendFailed(_ draft: Draft, _ error: Error) {
        let reason = error is MailMaybeSentError ? error.localizedDescription : "Not sent: " + error.localizedDescription
        if restore(draft) { banner = reason } else { unsent.append(Unsent(draft: draft, reason: reason)) }
        onSendFailure?(reason + " Open Mail in Jevcast to see your message.")
    }

    /// Sends a draft through Apple Mail, or through Jevcast's own accounts when they are the mail source.
    nonisolated static func deliver(_ draft: Draft, _ box: MailMailbox?) async throws {
        switch draft.mode {
        case .new:
            try await MailActions.send(to: MailActions.addresses(draft.to), cc: MailActions.addresses(draft.cc), subject: draft.subject, body: draft.body)
        case .reply(let all):
            guard let original = draft.original, let box else { throw LauncherError("The message to answer is no longer in the list.") }
            try await MailActions.reply(original, in: box, text: draft.body, all: all)
        case .forward:
            guard let original = draft.original, let box else { throw LauncherError("The message to answer is no longer in the list.") }
            try await MailActions.forward(original, in: box, text: draft.body, to: MailActions.addresses(draft.to))
        }
    }

    /// Puts a draft back in the composer when no draft with text is open.
    private func restore(_ back: Draft) -> Bool {
        if let draft, draft.hasContent { return false }
        draft = back
        return true
    }

    // MARK: Quill

    /// Writes the reply body from the instruction in the draft, such as "yes, but next week".
    /// The text goes only into the same draft, and only when its body did not change meanwhile.
    func draftWithQuill() {
        guard let current = draft, !quillBusy else { return }
        quillBusy = true
        let id = current.id, body = current.body, source = quillSource(current)
        let instruction = current.instruction
        Task { @MainActor [weak self] in
            defer { self?.quillBusy = false }
            do {
                guard let reply = try await self?.quill(.reply(message: source, instruction: instruction)), let self else { return }
                // Sent or discarded meanwhile: the text has no place to go.
                guard self.draft?.id == id else { return }
                guard self.draft?.body == body else {
                    self.composeNote = "Quill's text was not used because you changed the message."
                    return
                }
                self.draft?.body = reply.text
            } catch { self?.banner = error.localizedDescription }
        }
    }

    /// The answered message as Quill reads it: the text kept with the draft, not the selection.
    private func quillSource(_ draft: Draft) -> String {
        guard let original = draft.original, let message = draft.source?.message else { return "(No original message.)\nSubject: " + draft.subject }
        return "From: \(original.sender) <\(original.senderAddress)>\nSubject: \(original.subject)\nDate: \(original.date.formatted())\n\n"
            + String(message.readableText.prefix(30_000))
    }
}
