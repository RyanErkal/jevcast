import Foundation
import LauncherCore

struct MailFeatureSnapshot: Sendable {
    let boxes: [MailMailbox]
    let observations: [MailRuleMessage]
    let targets: [String: MailRuleNativeTarget]

    static func read(root: String, full: Bool) throws -> Self {
        let boxes = try MailStore.mailboxes(root: root)
        let selected = full ? boxes.filter(\.inAllMail) : boxes.filter { $0.role == .inbox }
        var query = MailStore.Query(mailboxes: selected.map(\.rowID), limit: 200, dedupe: true,
                                    preferred: Set(boxes.filter { $0.role == .inbox }.map(\.rowID)))
        var observations: [MailRuleMessage] = []
        var targets: [String: MailRuleNativeTarget] = [:]
        while !selected.isEmpty {
            try Task.checkCancellation()
            let page = try MailStore.page(root: root, query)
            for row in page.messages {
                guard let box = MailMailbox.actionTarget(for: row, in: boxes) else { continue }
                let key = box.accountID + ":" + row.messageKey
                guard targets[key] == nil else { continue }
                let detail = MailStore.message(root: root, mailbox: box, rowID: row.rowID)
                let recipients = [detail?.header("To"), detail?.header("Cc")].compactMap { $0 }.flatMap { MailAddress.list($0).map(\.address) }
                observations.append(.init(id: key, accountID: box.accountID, mailboxID: box.rowID, mailboxPath: box.path,
                    from: row.senderAddress, to: recipients, subject: row.subject, receivedAt: row.date, isRead: row.read, isFlagged: row.flagged))
                targets[key] = .init(summary: row, mailbox: box)
            }
            // Background arrivals are bounded; management previews explicitly scan all cached mail.
            guard page.hasMore, let last = page.last, full || observations.count < 1200 else { break }
            query.before = last
        }
        return .init(boxes: boxes, observations: observations, targets: targets)
    }
}
