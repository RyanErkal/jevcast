import Foundation

extension IMAPClient {
    /// Searches only exact Message-IDs, in bounded UID ranges. Used before repairing a Sent copy.
    ///
    /// When `after` is supplied, the search starts at that inclusive UID. A receipt captured just
    /// before APPEND uses this to prove that only the post-APPEND interval can contain its copy.
    /// SEARCH is only a candidate filter. Every candidate is fetched again and its parsed
    /// Message-ID must equal the requested value. The walk is deliberately bounded: a server that
    /// can expose only a recent MESSAGELIMIT window without UIDONLY cannot prove that an older
    /// message is absent, so this method refuses to report "not found" in that case.
    public func findMessageID(_ messageID: String, in mailbox: String, validity: UInt32, before upper: UInt32,
                              after lower: UInt32? = nil) async throws -> [UInt32] {
        guard MailServerDraftSupport.validMessageID(messageID) else {
            throw MailError.notFound("This saved message has an invalid Message-ID.")
        }

        let info = try await select(mailbox)
        guard info.uidValidity == validity else { throw MailError.uidValidityChanged(mailbox: mailbox) }
        let floor = max(1, lower ?? 1)
        guard upper > floor else { return [] }

        // Keep every SEARCH/FETCH below both the advertised limit and our own command bound.
        // A malformed MESSAGELIMIT=0 must not produce a zero-width range or a busy loop.
        var step = UInt32(max(1, min(messageLimit ?? 1_000, 1_000)))
        let highest = upper - 1
        let scanLimit: UInt32 = 20_000
        let first = highest - floor >= scanLimit ? highest - scanLimit + 1 : floor
        let limitedRecentView: Bool
        if !uidOnly, let advertised = messageLimit {
            let limit = UInt64(max(1, advertised))
            let rangeWidth = UInt64(highest) - UInt64(floor) + 1
            // A complete post-APPEND baseline makes this recent range safe even when older mail
            // is hidden by a non-UIDONLY server. Without that proof, the mailbox count must fit
            // the server window before an empty result can mean "not found".
            limitedRecentView = lower == nil ? UInt64(info.exists) > limit : rangeWidth > limit
        } else {
            limitedRecentView = false
        }
        var scanned: UInt64 = 0
        var ceiling = upper
        while ceiling > first {
            try Task.checkCancellation()
            let low = max(first, ceiling > step ? ceiling - step : first)
            let high = ceiling - 1
            let width = UInt64(high) - UInt64(low) + 1
            let matches: [UInt32]
            do {
                matches = try await exactMessageID(messageID, low: low, high: high, in: mailbox, validity: validity)
            } catch MailError.commandFailed(_, .no, _) where step > 1 {
                // Some servers advertise a generous limit but still reject a range. Halve the
                // next command instead of treating a refusal as proof that no copy exists.
                step = max(1, step / 2)
                continue
            }
            if !matches.isEmpty { return matches }
            scanned += width
            ceiling = low
        }
        let complete = first == floor && !limitedRecentView && scanned <= UInt64(scanLimit)
        guard complete else {
            throw MailError.notFound("Jevcast could not safely check all of Sent. Open Sent and try again; no copy was added.")
        }
        return []
    }

    private func exactMessageID(_ messageID: String, low: UInt32, high: UInt32, in mailbox: String, validity: UInt32) async throws -> [UInt32] {
        let candidates = try await exclusive {
            try await ensureSelected(mailbox, validity: validity)
            let reply = try await execute(IMAPCommand("UID SEARCH").raw("UID \(low):\(high) HEADER Message-ID").string(messageID))
            var candidates: [UInt32] = []
            for item in reply.untagged {
                if case .search(let values, _) = item { candidates += values }
                if case .esearch(let result) = item { candidates += result.all?.numbers ?? [] }
            }
            return Array(Set(candidates.filter { $0 >= low && $0 <= high })).sorted()
        }
        guard !candidates.isEmpty else { return [] }
        try Task.checkCancellation()
        let fetched = try await fetch(uids: IMAPSequenceSet(candidates),
                                      items: "(UID BODY.PEEK[HEADER.FIELDS (Message-ID)])",
                                      in: mailbox, validity: validity)
        try Task.checkCancellation()
        var fetchedByUID: [UInt32: IMAPFetch] = [:]
        var duplicateUID = false
        for item in fetched {
            guard let uid = item.uid else { continue }
            duplicateUID = duplicateUID || fetchedByUID.updateValue(item, forKey: uid) != nil
        }
        let candidateSet = Set(candidates)
        guard !duplicateUID, fetchedByUID.count == candidateSet.count, Set(fetchedByUID.keys) == candidateSet else {
            throw MailError.notFound("The server did not return every candidate header, so Jevcast could not safely check Sent.")
        }
        var matches: [UInt32] = []
        for uid in candidates {
            guard let header = fetchedByUID[uid]?.header else {
                throw MailError.notFound("The server returned an unreadable Message-ID header, so Jevcast could not safely check Sent.")
            }
            var raw = header
            raw.append(contentsOf: Data("\r\n\r\n".utf8))
            guard let parsed = MIMEMessage.parse(raw), parsed.header("Message-ID") != nil else {
                throw MailError.notFound("The server returned an unreadable Message-ID header, so Jevcast could not safely check Sent.")
            }
            // SEARCH is only a candidate filter. A valid, different header is a safe
            // non-match, such as when a server searched Message-ID as a substring.
            if parsed.header("Message-ID") == messageID { matches.append(uid) }
        }
        return matches
    }
}
