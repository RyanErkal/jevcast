import Foundation

/// The one quiet line at the bottom of Mail's sidebar that says how current the mail is:
/// "Updated 2 min ago", "Checking…", "Offline", or "1 account needs attention". The last one
/// names the account whose details open when you click it.
public struct MailSyncStatusLine: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case quiet, busy, offline, attention }

    public let text: String
    public let tone: Tone
    /// The account that needs attention first, for the click.
    public let accountID: String?

    public init(text: String, tone: Tone, accountID: String? = nil) {
        self.text = text; self.tone = tone; self.accountID = accountID
    }

    /// One of Jevcast's own accounts, as the sidebar knows it.
    public struct Account: Equatable, Sendable {
        public let id: String
        public let state: MailAccountSync.State?
        public let lastSync: Date?
        /// Changes made offline that failed or wait for review.
        public let needsReview: Bool
        public init(id: String, state: MailAccountSync.State?, lastSync: Date?, needsReview: Bool = false) {
            self.id = id; self.state = state; self.lastSync = lastSync; self.needsReview = needsReview
        }
        var failed: Bool { if case .failed = state { return true }; return false }
        var busy: Bool { state == .syncing || state == .starting }
    }

    /// Jevcast's own accounts. Offline comes first, since it is why every account stops. Nil
    /// without accounts.
    public static func native(_ accounts: [Account], online: Bool, checking: Bool, now: Date) -> MailSyncStatusLine? {
        guard !accounts.isEmpty else { return nil }
        if !online { return MailSyncStatusLine(text: "Offline", tone: .offline) }
        let attention = accounts.filter { $0.failed || $0.needsReview }
        if let first = attention.first {
            let text = attention.count == 1 ? "1 account needs attention" : "\(attention.count) accounts need attention"
            return MailSyncStatusLine(text: text, tone: .attention, accountID: first.id)
        }
        if checking || accounts.contains(where: \.busy) { return MailSyncStatusLine(text: "Checking…", tone: .busy) }
        guard let latest = accounts.compactMap(\.lastSync).max() else { return MailSyncStatusLine(text: "Not checked yet", tone: .quiet) }
        return MailSyncStatusLine(text: updated(latest, now: now), tone: .quiet)
    }

    /// Apple Mail fetches by itself; Jevcast knows only when it last asked it to. Nil before
    /// the first check, and while Apple Mail is closed, which the list's own note covers.
    public static func appleMail(running: Bool, checking: Bool, lastCheck: Date?, now: Date) -> MailSyncStatusLine? {
        if checking { return MailSyncStatusLine(text: "Checking…", tone: .busy) }
        guard running, let lastCheck else { return nil }
        return MailSyncStatusLine(text: updated(lastCheck, now: now), tone: .quiet)
    }

    /// "Updated just now", "Updated 2 min ago", "Updated 3 hr ago", or "Updated 2 days ago".
    public static func updated(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Updated just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "Updated \(hours) hr ago" }
        return "Updated \(hours / 24) days ago"
    }
}
