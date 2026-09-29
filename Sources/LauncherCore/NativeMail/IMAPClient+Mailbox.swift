import Foundation

extension IMAPClient {
    /// Every mailbox, with its special-use flags when the server sends them.
    public func listMailboxes() async throws -> [IMAPListEntry] {
        try await exclusive {
            let reply = try await execute(IMAPCommand("LIST").string("").string("*"))
            return reply.untagged.compactMap { if case .list(let entry) = $0 { return entry }; return nil }
        }
    }

    /// Selects `mailbox` and returns what SELECT reported.
    public func select(_ mailbox: String) async throws -> MailboxInfo {
        try await exclusive { try await ensureSelected(mailbox, validity: nil, fresh: true) }
    }

    /// Selects `mailbox` unless it already is. With `validity`, a mailbox the server renumbered
    /// throws, so old UIDs are never used against new messages.
    @discardableResult
    func ensureSelected(_ mailbox: String, validity: UInt32?, fresh: Bool = false) async throws -> MailboxInfo {
        if !fresh, let selected, selected.name == mailbox {
            // A selection made before sync saw the new numbering is checked again before it fails.
            if let validity, selected.uidValidity != validity { return try await ensureSelected(mailbox, validity: validity, fresh: true) }
            return selected
        }
        selected = nil
        var command = IMAPCommand("SELECT").mailbox(mailbox)
        if has("CONDSTORE") { command = command.raw("(CONDSTORE)") }
        let reply = try await execute(command)
        var info = MailboxInfo(name: mailbox, uidValidity: 0, uidNext: nil, exists: 0, highestModSeq: nil, readOnly: false)
        for data in reply.untagged {
            switch data {
            case .exists(let count): info.exists = count
            case .status(let status):
                guard let code = status.code else { continue }
                switch code.name {
                case "UIDVALIDITY": info.uidValidity = code.number.flatMap(UInt32.init(exactly:)) ?? 0
                case "UIDNEXT": info.uidNext = code.number.flatMap(UInt32.init(exactly:))
                case "HIGHESTMODSEQ": info.highestModSeq = code.number
                default: break
                }
            default: break
            }
        }
        info.readOnly = reply.status.code?.name == "READ-ONLY"
        selected = info
        if let validity, info.uidValidity != validity { throw MailError.uidValidityChanged(mailbox: mailbox) }
        return info
    }

    /// The selected mailbox's state, after the commands so far.
    public func current(_ mailbox: String) -> MailboxInfo? { selected?.name == mailbox ? selected : nil }

    /// UID FETCH in chunks. Only replies that name a UID in `set` are kept, since `n:*` also
    /// matches the highest UID when every UID is below n.
    public func fetch(uids set: IMAPSequenceSet, items: String, changedSince: UInt64? = nil,
                      in mailbox: String, validity: UInt32?) async throws -> [IMAPFetch] {
        guard !set.isEmpty else { return [] }
        var result: [IMAPFetch] = []
        for chunk in set.chunked() {
            let fetched = try await exclusive {
                try await ensureSelected(mailbox, validity: validity)
                var command = IMAPCommand("UID FETCH").raw(chunk.description).raw(items)
                if let changedSince { command = command.raw("(CHANGEDSINCE \(changedSince))") }
                return try await execute(command).untagged
            }
            for case .fetch(_, let data) in fetched { if let uid = data.uid, chunk.contains(uid) { result.append(data) } }
        }
        return result
    }

    /// UIDs from `first` up, for new mail: `first:*`, keeping only UIDs at or above `first`.
    public func fetch(from first: UInt32, items: String, in mailbox: String, validity: UInt32?) async throws -> [IMAPFetch] {
        let fetched = try await exclusive {
            try await ensureSelected(mailbox, validity: validity)
            return try await execute(IMAPCommand("UID FETCH").raw("\(first):*").raw(items)).untagged
        }
        return fetched.compactMap { if case .fetch(_, let data) = $0, let uid = data.uid, uid >= first { return data }; return nil }
    }

    /// FETCH by message number, such as the newest 500: `exists-499:exists`. Items must include UID.
    public func fetch(sequence range: ClosedRange<UInt32>, items: String, in mailbox: String, validity: UInt32?) async throws -> [IMAPFetch] {
        let fetched = try await exclusive {
            try await ensureSelected(mailbox, validity: validity)
            return try await execute(IMAPCommand("FETCH").raw("\(range.lowerBound):\(range.upperBound)").raw(items)).untagged
        }
        return fetched.compactMap { if case .fetch(_, let data) = $0, data.uid != nil { return data }; return nil }
    }

    /// UID SEARCH with fixed criteria text from code, such as "UID 100:*" or "ALL".
    public func search(_ criteria: String, in mailbox: String, validity: UInt32?) async throws -> IMAPSequenceSet {
        try await exclusive {
            try await ensureSelected(mailbox, validity: validity)
            if has("ESEARCH") {
                let reply = try await execute(IMAPCommand("UID SEARCH").raw("RETURN (ALL)").raw(criteria))
                for case .esearch(let result) in reply.untagged { return result.all ?? IMAPSequenceSet([]) }
                return IMAPSequenceSet([])
            }
            let reply = try await execute(IMAPCommand("UID SEARCH").raw(criteria))
            var numbers: [UInt32] = []
            for case .search(let found, _) in reply.untagged { numbers += found }
            return IMAPSequenceSet(numbers)
        }
    }

    /// Adds or removes flags, such as `\Seen`, without asking the server to echo them.
    public func store(uids set: IMAPSequenceSet, add: Bool, flags: [String], in mailbox: String, validity: UInt32?) async throws {
        for chunk in set.chunked() {
            try await exclusive {
                try await ensureSelected(mailbox, validity: validity)
                _ = try await execute(IMAPCommand("UID STORE").raw(chunk.description)
                    .raw((add ? "+" : "-") + "FLAGS.SILENT").raw("(" + flags.joined(separator: " ") + ")"))
            }
        }
    }

    /// Moves messages to `destination`. Without MOVE it copies, marks the originals deleted, and
    /// expunges them: only those UIDs with UIDPLUS, or every deleted message without it.
    public func move(uids set: IMAPSequenceSet, to destination: String, in mailbox: String, validity: UInt32?) async throws {
        try await exclusive {
            try await ensureSelected(mailbox, validity: validity)
            if has("MOVE") {
                _ = try await execute(IMAPCommand("UID MOVE").raw(set.description).mailbox(destination))
                return
            }
            _ = try await execute(IMAPCommand("UID COPY").raw(set.description).mailbox(destination))
            _ = try await execute(IMAPCommand("UID STORE").raw(set.description).raw("+FLAGS.SILENT (\\Deleted)"))
            if has("UIDPLUS") { _ = try await execute(IMAPCommand("UID EXPUNGE").raw(set.description)) }
            else { _ = try await execute(IMAPCommand("EXPUNGE")) }
        }
    }

    /// Deletes messages for good, as from Trash.
    public func expunge(uids set: IMAPSequenceSet, in mailbox: String, validity: UInt32?) async throws {
        try await exclusive {
            try await ensureSelected(mailbox, validity: validity)
            _ = try await execute(IMAPCommand("UID STORE").raw(set.description).raw("+FLAGS.SILENT (\\Deleted)"))
            if has("UIDPLUS") { _ = try await execute(IMAPCommand("UID EXPUNGE").raw(set.description)) }
            else { _ = try await execute(IMAPCommand("EXPUNGE")) }
        }
    }

    /// Adds a message to `mailbox`, such as a sent copy. Returns its UID when the server says.
    /// Not retried, so a lost reply cannot add the message twice.
    @discardableResult
    public func append(_ message: Data, to mailbox: String, flags: [String], date: Date? = nil) async throws -> UInt32? {
        try await exclusive(retry: false) {
            var command = IMAPCommand("APPEND").mailbox(mailbox).raw("(" + flags.joined(separator: " ") + ")")
            if let date { command = command.raw("\"" + IMAPDate.format(date) + "\"") }
            let reply = try await execute(command.literal(message))
            guard let code = reply.status.code, code.name == "APPENDUID", code.values.count == 2 else { return nil }
            return code.values[1].number.flatMap(UInt32.init(exactly:))
        }
    }

    public func noop() async throws {
        try await exclusive { _ = try await execute(IMAPCommand("NOOP")) }
    }
}
