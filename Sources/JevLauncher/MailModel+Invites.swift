import Foundation
import LauncherCore

/// Meeting invitations and mailing lists in the message on screen. Every send here follows one
/// click by the user, goes from the account that received the message, and uses its own SMTP server.
extension MailModel {
    /// The account that received the selected message, when it is one of Jevcast's own accounts.
    private var inviteAccount: NativeMailAccount? {
        guard NativeMailCenter.isActive, let message = selected, let box = actionBox(message) else { return nil }
        return NativeMailCenter.shared.accounts.first { $0.id == box.accountID }
    }

    /// True when Accept, Maybe, and Decline can send an answer: a request, in a Jevcast account.
    var canAnswerInvite: Bool { invite?.canReply == true && (inviteAccount != nil || isDemo) }

    /// Your answer to the invitation on screen: the one sent from this Mac, or the one the invitation records.
    var inviteAnswer: CalendarInvite.Response? {
        guard let invite else { return nil }
        if let sent = inviteAnswers[invite.uid], let answer = CalendarInvite.Response(rawValue: sent) { return answer }
        guard let account = inviteAccount else { return nil }
        return invite.attendee(among: ownAddresses(account)).flatMap { CalendarInvite.Response(rawValue: $0.status) }
    }

    private func ownAddresses(_ account: NativeMailAccount) -> [String] {
        [account.email] + senders.filter { $0.accountID == account.id && $0.providerAuthorized }.map(\.address)
    }

    /// Sends your answer to the organizer as a standard calendar reply.
    func answerInvite(_ response: CalendarInvite.Response) {
        guard !inviteBusy, let invite, invite.canReply, let organizer = invite.organizer, let account = inviteAccount,
              let engine = NativeMailCenter.activeEngine else { return }
        // The invitation names you by the address it was sent to. Without a match, the account's address answers.
        let me = invite.attendee(among: ownAddresses(account))
        let address = me?.address ?? account.email
        let name = me?.name.isEmpty == false ? me!.name : account.name
        let calendar = invite.reply(response, from: address, name: name)
        let subject = invite.replySubject(response)
        let who = name.isEmpty ? address : name
        let body = who + " " + (response == .accepted ? "accepted" : response == .declined ? "declined" : "tentatively accepted")
            + " the invitation: " + (invite.title.isEmpty ? "Invitation" : invite.title) + "\n"
        let inReplyTo = detail?.header("Message-ID")
        let uid = invite.uid, accountID = account.id
        inviteBusy = true
        Task { @MainActor [weak self] in
            defer { self?.inviteBusy = false }
            do {
                try await engine.sendInvitationReply(from: accountID, to: MailContact(name: organizer.name, address: organizer.address),
                                                     subject: subject, body: body, calendar: calendar, inReplyTo: inReplyTo)
                guard let self else { return }
                self.inviteAnswers[uid] = response.rawValue
                // Only the newest answers are kept.
                if self.inviteAnswers.count > 400 { self.inviteAnswers = [uid: response.rawValue] }
                self.mailDefaults?.set(self.inviteAnswers, forKey: "mailInviteAnswers")
                self.banner = response.verb + ". " + (organizer.name.isEmpty ? organizer.address : organizer.name) + " was told."
            } catch { self?.banner = "The answer was not sent: " + error.localizedDescription }
        }
    }

    /// Leaves the mailing list of the message on screen: sends the list's own unsubscribe email from
    /// the account that received the message, or returns the list's web page to open in the browser.
    /// Jevcast never requests the web page itself.
    func unsubscribeFromList() -> URL? {
        guard let unsubscribe, !inviteBusy else { return nil }
        guard let link = unsubscribe.mail, let to = link.to.first, let account = inviteAccount, let engine = NativeMailCenter.activeEngine else {
            return unsubscribe.web
        }
        let accountID = account.id
        inviteBusy = true
        Task { @MainActor [weak self] in
            defer { self?.inviteBusy = false }
            do {
                try await engine.send(from: accountID, to: [to], cc: [], subject: link.subject.isEmpty ? "unsubscribe" : link.subject,
                                      body: link.body.isEmpty ? "unsubscribe\n" : link.body)
                self?.banner = "Unsubscribe request sent to " + to + "."
            } catch { self?.banner = "The unsubscribe request was not sent: " + error.localizedDescription }
        }
        return nil
    }

    /// Opens a `mailto:` link as a new message here, in place of another mail app.
    @discardableResult
    func compose(link: MailtoLink) -> Bool {
        startDraft(Draft(to: link.to.joined(separator: ", "), cc: link.cc.joined(separator: ", "),
                         bccText: link.bcc.isEmpty ? nil : link.bcc.joined(separator: ", "), subject: link.subject, body: link.body))
    }
}
