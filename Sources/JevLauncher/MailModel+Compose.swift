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
        var chosen = new
        if chosen.fromAccountID == nil { selectInitialSender(&chosen) }
        chosen.fillRecipients()
        draft = chosen
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
        var ready = draft
        ready.source = source
        if !ready.senderWasChosen { selectInitialSender(&ready) }
        ready.fillRecipients()
        self.draft = ready
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
        do { try saveComposition() } catch { banner = error.localizedDescription }
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
        recordDelivery(draft, state: .queued)
        do { try saveComposition() }
        catch { composeNote = "Nothing was sent. " + error.localizedDescription; return composeNote }
        unsent.removeAll { $0.id == draft.id }
        queue(draft, box: draft.original.flatMap(actionBox))
        self.draft = nil
        banner = nil
        return nil
    }

    private func refusal(_ draft: Draft) -> String? {
        if quillBusy { return "Wait until Quill finishes writing." }
        if let problem = draft.sendProblem { return problem }
        if let persistenceProblem { return "Nothing was sent. " + persistenceProblem }
        if draft.backend != MailBackend.current.rawValue { return "This draft uses another mail source. Select its source in Settings › Mail before sending." }
        guard senders.contains(where: { $0.accountID == draft.fromAccountID && $0.address == draft.fromAddress }) else { return "Select an available sending account." }
        // Jevcast's own accounts answer from the copy kept with the draft, so a message archived
        // during the undo time still gets its reply. Apple Mail needs the message in its mailbox.
        if draft.mode != .new, draft.backend != MailBackend.jevcast.rawValue, draft.original.flatMap(actionBox) == nil {
            return "The message to answer is no longer in the list."
        }
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
                guard draft.backend == MailBackend.current.rawValue else { throw LauncherError("The mail source changed. Nothing was sent.") }
                self.recordDelivery(draft, state: .sending)
                try self.saveComposition()
                try await action(draft, box)
                self.recordDelivery(draft, state: .sent)
                self.banner = "Sent."
            } catch {
                self.sendFailed(draft, error)
            }
            do { try self.saveComposition() } catch { self.banner = "The send result could not be saved. Check Outbox before resending. " + error.localizedDescription }
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
        do { try saveComposition() } catch { banner = error.localizedDescription }
    }

    /// Stops a send during its undo time. The draft comes back, or waits in `unsent` while
    /// another draft with text is open.
    func undoSend() {
        guard let pending = pendingSend, let ticket = pendingTicket else { return }
        pendingSend = nil; pendingTicket = nil; sendsAt = nil
        undoneSends.insert(ticket)
        sendsInFlight -= 1
        undoTimer?.cancel(); undoTimer = nil
        recordDelivery(pending, state: .undone)
        if restore(pending) { banner = "Not sent. Your message is back." }
        else { unsent.append(Unsent(draft: pending, reason: "Not sent. Your message is kept.")) }
        do { try saveComposition() } catch { banner = error.localizedDescription }
    }

    /// Nothing typed is lost: the draft comes back with the reason, or waits in `unsent`. When Mail
    /// may have sent it, the note says to check Sent instead of "Not sent".
    private func sendFailed(_ draft: Draft, _ error: Error) {
        var draft = draft
        let uncertain = error is MailMaybeSentError || (error as? MailError) == .deliveryUncertain
        draft.uncertainSend = uncertain
        let reason = uncertain ? error.localizedDescription : "Not sent: " + error.localizedDescription
        recordDelivery(draft, state: uncertain ? .uncertain : .failed, note: reason)
        if restore(draft) { banner = reason } else { unsent.append(Unsent(draft: draft, reason: reason)) }
        onSendFailure?(reason + " Open Mail in Jevcast to see your message.")
    }

    /// Sends a draft through Apple Mail, or through Jevcast's own accounts when they are the mail source.
    nonisolated static func deliver(_ draft: Draft, _ box: MailMailbox?) async throws {
        try MailIOPolicy.requireOnline()
        guard draft.backend == MailBackend.current.rawValue else { throw LauncherError("The mail source changed. Nothing was sent.") }
        guard let accountID = draft.fromAccountID, let address = draft.fromAddress else { throw LauncherError("Select a sending account.") }
        guard draft.body.utf8.count <= 1024 * 1024, draft.attachments.reduce(0, { $0 + $1.data.count }) <= MailComposeAttachments.byteLimit else {
            throw LauncherError("This message is too large. Reduce its text or attachments.")
        }
        var html = MailRichText.html(draft.richText, plain: draft.body)
        for image in draft.attachments where image.contentID != nil {
            html += "<p><img style=\"max-width:100%\" src=\"cid:" + MailHTML.escape(image.contentID ?? "") + "\" alt=\"" + MailHTML.escape(image.filename) + "\"></p>"
        }
        if NativeMailCenter.isActive {
            guard let engine = NativeMailCenter.activeEngine else { throw LauncherError("Add a mail account in Settings › Mail first.") }
            guard await engine.accounts.contains(where: { $0.id == accountID && $0.email == address }) else {
                throw LauncherError("The selected sending account changed. Nothing was sent.")
            }
            // The fields as you left them, with names, go out; nothing is worked out again at send time.
            let recipients = NativeMailEngine.Recipients(to: try MailActions.contacts(draft.to), cc: try MailActions.contacts(draft.cc),
                                                         bcc: try MailActions.contacts(draft.bcc))
            switch draft.mode {
            case .new:
                try await engine.send(from: accountID, to: [], cc: [], subject: draft.subject, body: draft.body, html: html,
                                      attachments: draft.attachments, messageID: draft.sendingMessageID, recipients: recipients)
            case .reply(let all):
                guard let original = draft.original, let source = draft.source else { throw LauncherError("Wait until the original message has loaded.") }
                try await engine.reply(to: original.rowID, text: draft.body, all: all, from: accountID, html: html, attachments: draft.attachments,
                                       messageID: draft.sendingMessageID, expectedMessageID: source.message.header("Message-ID"),
                                       recipients: recipients, subject: draft.subject, quote: draft.includesQuote,
                                       saved: source.message, savedDate: original.date)
            case .forward:
                guard let original = draft.original, let source = draft.source else { throw LauncherError("Wait until the original message has loaded.") }
                try await engine.forward(original.rowID, text: draft.body, to: [], from: accountID, html: html, attachments: draft.attachments,
                                         messageID: draft.sendingMessageID, expectedMessageID: source.message.header("Message-ID"),
                                         recipients: recipients, subject: draft.subject, saved: source.message, savedDate: original.date)
            }
            return
        }
        switch draft.mode {
        case .new:
            try await MailActions.send(to: MailActions.addresses(draft.to), cc: MailActions.addresses(draft.cc), subject: draft.subject, body: draft.body,
                                       accountID: accountID, address: address, attachments: draft.attachments)
        case .reply(let all):
            guard let original = draft.original, let box else { throw LauncherError("The message to answer is no longer in the list.") }
            try await MailActions.reply(original, in: box, text: draft.body, all: all, accountID: accountID, address: address,
                                        attachments: draft.attachments, expectedMessageID: draft.source?.message.header("Message-ID"))
        case .forward:
            guard let original = draft.original, let box else { throw LauncherError("The message to answer is no longer in the list.") }
            try await MailActions.forward(original, in: box, text: draft.body, to: MailActions.addresses(draft.to), accountID: accountID, address: address,
                                          attachments: draft.attachments, expectedMessageID: draft.source?.message.header("Message-ID"))
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
                self.draft?.richText = nil
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
