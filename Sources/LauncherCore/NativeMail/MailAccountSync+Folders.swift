import Foundation

/// A user's own folders: make one, rename one, or remove an empty one. The account's standard
/// mailboxes, such as Inbox, Sent, and Trash, cannot be renamed or removed here.
extension MailAccountSync {
    /// A single folder name as typed: no path separator, no control characters, 1 to 120 characters.
    public static func folderName(_ typed: String, delimiter: String?) throws -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw MailError.notFound("Type a folder name of 1 to 120 characters.")
        }
        if let delimiter, !delimiter.isEmpty, name.contains(delimiter) {
            throw MailError.notFound("A folder name cannot contain “\(delimiter)”.")
        }
        guard !name.contains("*"), !name.contains("%") else { throw MailError.notFound("A folder name cannot contain * or %.") }
        return name
    }

    private var folderDelimiter: String { mailboxes.compactMap(\.delimiter).first { !$0.isEmpty } ?? "/" }

    private func taken(_ full: String) -> Bool { mailboxes.contains { $0.name.caseInsensitiveCompare(full) == .orderedSame } }

    public func createFolder(_ typed: String, under parent: NativeMailStore.Mailbox?) async throws {
        let delimiter = parent?.delimiter ?? folderDelimiter
        let name = try Self.folderName(typed, delimiter: delimiter)
        let full = parent.map { $0.name + delimiter + name } ?? name
        guard !taken(full) else { throw MailError.notFound("A folder with this name already exists.") }
        try await actionClient.createMailbox(full)
        await relist()
    }

    public func renameFolder(_ box: NativeMailStore.Mailbox, to typed: String) async throws {
        guard box.role == nil || box.role == .other else { throw MailError.notFound("This is one of the account's standard mailboxes. It cannot be renamed here.") }
        let delimiter = box.delimiter ?? folderDelimiter
        let name = try Self.folderName(typed, delimiter: delimiter)
        var parts = box.name.components(separatedBy: delimiter)
        parts[parts.count - 1] = name
        let full = parts.joined(separator: delimiter)
        guard full != box.name else { return }
        guard !taken(full) else { throw MailError.notFound("A folder with this name already exists.") }
        try await actionClient.renameMailbox(box.name, to: full)
        await relist()
    }

    /// Removes a folder of your own that holds no messages and no folders. Nothing is deleted with it.
    public func deleteEmptyFolder(_ box: NativeMailStore.Mailbox) async throws {
        guard box.role == nil || box.role == .other else { throw MailError.notFound("This is one of the account's standard mailboxes. It cannot be removed.") }
        let delimiter = box.delimiter ?? folderDelimiter
        guard !mailboxes.contains(where: { $0.name.hasPrefix(box.name + delimiter) }) else {
            throw MailError.notFound("This folder holds other folders. Remove or move them first. Nothing was changed.")
        }
        try await actionClient.deleteEmptyMailbox(box.name)
        await relist()
    }
}
