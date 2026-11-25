import SwiftUI
import LauncherCore

/// Delete All from a sender, counted first: the sender and exactly the messages that move to Trash.
struct MailSenderDeleteRequest: Identifiable, Equatable {
    /// One counted message, as it was when it was counted. On confirm a message moves only when
    /// all of this still matches, so a row number the list gave to another message never moves.
    struct Target: Equatable {
        let backend: MailBackend
        let accountID: String
        let mailboxID: Int64
        let rowID: Int64
        let messageKey: String
        let senderAddress: String
        /// Also checked, because Apple Mail's message key can be only the row number.
        let date: Date
        let subject: String
    }

    let id = UUID()
    /// The sender as the list shows it, such as "Ada" or an address.
    let sender: String
    let address: String
    let targets: [Target]
    var rowIDs: [Int64] { targets.map(\.rowID) }
    var count: Int { targets.count }
    var noun: String { Self.noun(count) }
    static func noun(_ count: Int) -> String { count == 1 ? "1 message" : "\(count) messages" }
}

extension MailModel {
    /// Counts every listed message from the selected message's sender, then asks. Nothing moves
    /// until you confirm. Messages in Trash are never counted: there a delete would be for good.
    func deleteAllFromSender() {
        guard let message = selected, !refuses(.deleteAllFromSender) else { return }
        let address = message.senderAddress
        guard !address.isEmpty else { return }
        let targets = messages.compactMap { senderDeleteTarget($0, address: address) }
        guard !targets.isEmpty else { return }
        senderDeleteRequest = MailSenderDeleteRequest(sender: message.sender.isEmpty ? address : message.sender,
                                                      address: address, targets: targets)
    }

    /// Moves the counted messages that still match exactly to Trash, and never deletes for good.
    /// Each one is read again from Mail's index now, not from the list on screen; a row that
    /// cannot be read or no longer matches is skipped. The Undo note says what moved; when that
    /// is fewer than counted, it says so.
    @discardableResult
    func confirmDeleteAllFromSender() -> Task<Void, Never>? {
        guard let request = senderDeleteRequest else { return nil }
        senderDeleteRequest = nil
        let read = readRows
        return Task { @MainActor [weak self] in
            let fresh = await read(request.rowIDs) ?? []
            guard let self else { return }
            let current = fresh.compactMap { message -> (MailSummary, MailMailbox)? in
                guard let target = self.senderDeleteTarget(message, address: request.address), request.targets.contains(target),
                      let box = self.actionBox(message) else { return nil }
                return (message, box)
            }
            guard !current.isEmpty else { self.banner = "These messages changed or are no longer in Mail. Nothing was deleted."; return }
            let moved = MailSenderDeleteRequest.noun(current.count)
            let title = current.count == request.count
                ? "Moved \(moved) from \(request.sender) to Trash"
                : "Moved \(current.count) of \(request.count) messages from \(request.sender) to Trash"
            self.moveToTrash(current, title: title)
        }
    }

    /// `message` as a target of Delete All from `address`, or nil when it is from someone else,
    /// its mailbox is unknown, or it is in Trash.
    private func senderDeleteTarget(_ message: MailSummary, address: String) -> MailSenderDeleteRequest.Target? {
        guard message.senderAddress.caseInsensitiveCompare(address) == .orderedSame,
              let box = actionBox(message), box.role != .trash else { return nil }
        return .init(backend: MailBackend.current, accountID: box.accountID, mailboxID: box.rowID, rowID: message.rowID,
                     messageKey: message.messageKey, senderAddress: message.senderAddress.lowercased(),
                     date: message.date, subject: message.subject)
    }
}

/// The question before Delete All from a sender, with the count and the sender.
struct MailSenderDeletePrompt: ViewModifier {
    @ObservedObject var model: MailModel

    func body(content: Content) -> some View {
        let request = model.senderDeleteRequest
        return content.alert(Text(request.map { "Move \($0.noun) from \($0.sender) to Trash?" } ?? ""),
                             isPresented: Binding(get: { model.senderDeleteRequest != nil }, set: { if !$0 { model.senderDeleteRequest = nil } })) {
            Button("Cancel", role: .cancel) { model.senderDeleteRequest = nil }
            Button("Move to Trash", role: .destructive) { model.confirmDeleteAllFromSender() }
        } message: {
            Text(request.map { "Every message from \($0.address) in this list moves to Trash. You can undo this for a few seconds." } ?? "")
        }
    }
}
