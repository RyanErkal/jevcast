import Contacts
import Foundation
import LauncherCore

/// Contacts access is intentionally split into status, request, and read operations. Reading a
/// contact never happens from a model initializer or mail startup path.
enum MailContactsSuggestionSource {
    static var authorizationStatus: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    static func requestAccess() async -> Bool {
        guard authorizationStatus == .notDetermined else { return authorizationStatus == .authorized }
        return (try? await CNContactStore().requestAccess(for: .contacts)) == true
    }

    static func suggestions(query: String) async -> [MailRecipientSuggestion] {
        guard authorizationStatus == .authorized else { return [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor,
                                       CNContactFamilyNameKey as CNKeyDescriptor,
                                       CNContactEmailAddressesKey as CNKeyDescriptor]
        guard let contacts = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys) else {
            return []
        }
        var result: [MailRecipientSuggestion] = []
        var seen = Set<String>()
        for contact in contacts {
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            for value in contact.emailAddresses {
                let address = String(value.value).trimmingCharacters(in: .whitespacesAndNewlines)
                guard MailRecipientParser.isAddress(address), seen.insert(address.lowercased()).inserted else { continue }
                result.append(.init(contact: MailContact(name: name, address: address), source: .contacts))
            }
        }
        return result
    }

    /// The user-facing opt-in affordance uses this method after permission is granted. It still
    /// requires a query, so a large address book is never loaded just because Mail opened.
    static func requestAndSuggest(query: String) async -> [MailRecipientSuggestion] {
        guard await requestAccess() else { return [] }
        return await suggestions(query: query)
    }
}

extension MailModel {
    /// Addresses already visible in this local store. This includes sender summaries, loaded
    /// message headers, and locally saved composition values. It never reads Contacts or a server.
    var localMailRecipientSuggestions: [MailRecipientSuggestion] {
        var contacts: [MailContact] = []
        var seen = Set<String>()

        func add(_ contact: MailContact) {
            let address = contact.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MailRecipientParser.isAddress(address), seen.insert(address.lowercased()).inserted else { return }
            contacts.append(.init(name: contact.name, address: address))
        }

        for message in messages {
            add(.init(name: message.senderName, address: message.senderAddress))
        }
        for identity in senders where identity.isAlias {
            let address = identity.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MailRecipientParser.isAddress(address), seen.insert(address.lowercased()).inserted else { continue }
            contacts.append(.init(name: identity.name, address: address))
        }
        for draft in ([draft].compactMap { $0 } + unsent.map(\.draft) + deliveries.compactMap(\.draft)) {
            for field in [draft.to, draft.cc, draft.bcc] {
                for recipient in MailRecipientParser.parse(field).compactMap(\.recipient) { add(recipient.contact) }
            }
        }
        if let detail {
            for header in ["From", "Reply-To", "To", "Cc", "Bcc"] {
                for address in MailAddress.list(detail.header(header) ?? "") {
                    add(.init(name: address.name, address: address.address))
                }
            }
        }
        return contacts.map { contact in
            let source: MailRecipientSuggestion.Source = senders.contains { $0.isAlias && $0.address.caseInsensitiveCompare(contact.address) == .orderedSame } ? .alias : .localMail
            return MailRecipientSuggestion(contact: contact, source: source)
        }
    }

    func recipientSuggestions(for query: String) -> [MailRecipientSuggestion] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return localMailRecipientSuggestions.filter { normalized.isEmpty
            || $0.contact.name.lowercased().contains(normalized)
            || $0.contact.address.lowercased().contains(normalized) }
    }
}
