import Foundation
import LauncherCore

extension MailModel {
    var queryPlace: Place { !search.isEmpty && searchScope == .allAccounts ? .allMail : place }
    var unreadEverywhere: Int { mailboxes.filter(\.inAllMail).map { $0.serverUnread ?? $0.unread }.reduce(0, +) }
    var favoriteMailboxes: [MailMailbox] { MailPlacePicker.ordered(mailboxes.filter(isFavorite)) }
    var pendingDeliveryCount: Int { deliveries.filter { [.queued, .sending, .sentCopyPending, .appleMailQueued, .failed, .uncertain].contains($0.state) }.count }
    var savedDrafts: [Draft] {
        var result = draft.map { [$0] } ?? []
        for item in unsent where !result.contains(where: { $0.id == item.id }) { result.append(item.draft) }
        return result
    }
    func isFavorite(_ box: MailMailbox) -> Bool { favoriteMailboxKeys.contains(box.url) }
    func toggleFavorite(_ box: MailMailbox) {
        if !favoriteMailboxKeys.insert(box.url).inserted { favoriteMailboxKeys.remove(box.url) }
        mailDefaults?.set(favoriteMailboxKeys.sorted(), forKey: "mailFavoriteMailboxes")
    }
    func setMailboxExpanded(_ key: String, _ expanded: Bool) {
        if expanded { collapsedMailboxKeys.remove(key) } else { collapsedMailboxKeys.insert(key) }
        mailDefaults?.set(collapsedMailboxKeys.sorted(), forKey: "mailCollapsedMailboxes")
    }
    func restoreSavedDraft(_ saved: Draft) {
        // The open draft, picked again: it shows as it is, with no new recipients or sender.
        if draft?.id == saved.id { draftNudge += 1 } else if !startDraft(saved) { return }
        unsent.removeAll { $0.id == saved.id }
    }
}
