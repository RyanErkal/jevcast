import Foundation

extension NativeMailEngine {
    /// Saves a draft in the selected account's mapped server Drafts folder. The account sync
    /// resolver is kept in NativeMailEngine's actor-owned implementation.
    public func saveServerDraft(from accountID: String, raw: Data, messageID: String,
                                replacing: MailServerDraftReference? = nil) async throws -> MailServerDraftReference {
        let sync = try accountSync(accountID)
        return try await sync.saveServerDraft(raw, messageID: messageID, replacing: replacing)
    }

    /// Removes only the exact server draft identified by a previously returned reference.
    public func removeServerDraft(_ reference: MailServerDraftReference) async throws {
        let sync = try accountSync(reference.accountID)
        try await sync.removeServerDraft(reference)
    }
}
