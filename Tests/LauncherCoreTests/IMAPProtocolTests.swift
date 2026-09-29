import XCTest
@testable import LauncherCore

final class IMAPProtocolTests: XCTestCase {
    private func parse(_ text: String) throws -> IMAPResponse { try IMAPParser.parse(Array(text.utf8)) }

    // MARK: Parser

    func testTaggedStatusWithCode() throws {
        XCTAssertEqual(try parse("J7 OK [READ-WRITE] SELECT completed\r\n"),
                       .tagged(tag: "J7", IMAPStatusText(status: .ok, code: IMAPResponseCode(name: "READ-WRITE", values: []), text: "SELECT completed")))
        guard case .tagged(_, let status) = try parse("J8 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n") else { return XCTFail() }
        XCTAssertEqual(status.status, .no)
        XCTAssertEqual(status.code?.name, "AUTHENTICATIONFAILED")
        XCTAssertEqual(status.text, "Invalid credentials (Failure)")
    }

    func testUntaggedCodesAndCounts() throws {
        guard case .untagged(.status(let validity)) = try parse("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n") else { return XCTFail() }
        XCTAssertEqual(validity.code?.number, 3_857_529_045)
        guard case .untagged(.status(let flags)) = try parse("* OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n") else { return XCTFail() }
        XCTAssertEqual(flags.code?.values.first?.list?.compactMap(\.text), ["\\Deleted", "\\Seen", "\\*"])
        guard case .tagged(_, let append) = try parse("J9 OK [APPENDUID 38505 3955] APPEND completed\r\n") else { return XCTFail() }
        XCTAssertEqual(append.code?.values.compactMap(\.number), [38505, 3955])
        guard case .untagged(.status(let copy)) = try parse("* OK [COPYUID 38505 304,319:320 3956:3958] Done\r\n") else { return XCTFail() }
        XCTAssertEqual(copy.code?.values.compactMap(\.text), ["38505", "304,319:320", "3956:3958"])
        XCTAssertEqual(try parse("* 23 EXISTS\r\n"), .untagged(.exists(23)))
        XCTAssertEqual(try parse("* 5 EXPUNGE\r\n"), .untagged(.expunge(5)))
        XCTAssertEqual(try parse("+ idling\r\n"), .continuation("idling"))
        XCTAssertEqual(try parse("+\r\n"), .continuation(""))
    }

    func testCapabilityAndUnknownReplies() throws {
        XCTAssertEqual(try parse("* CAPABILITY IMAP4rev1 IDLE AUTH=PLAIN X-GM-EXT-1\r\n"), .untagged(.capability(["IMAP4rev1", "IDLE", "AUTH=PLAIN", "X-GM-EXT-1"])))
        XCTAssertEqual(try parse("* ID (\"name\" \"Fake\")\r\n"), .untagged(.other("ID")))
        XCTAssertEqual(try parse("* ENABLED CONDSTORE\r\n"), .untagged(.enabled(["CONDSTORE"])))
        // A code the parser does not know keeps its text.
        guard case .untagged(.status(let alert)) = try parse("* OK [WEBALERT https://example.com/x?y=1] Sign in\r\n") else { return XCTFail() }
        XCTAssertEqual(alert.code?.name, "WEBALERT")
        XCTAssertEqual(alert.text, "Sign in")
    }

    func testListEntries() throws {
        guard case .untagged(.list(let gmail)) = try parse("* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Sent Mail\"\r\n") else { return XCTFail() }
        XCTAssertEqual(gmail.name, "[Gmail]/Sent Mail")
        XCTAssertEqual(gmail.delimiter, "/")
        XCTAssertTrue(gmail.has("\\sent"))
        XCTAssertTrue(gmail.selectable)
        guard case .untagged(.list(let german)) = try parse("* LIST () \".\" Entw&APw-rfe\r\n") else { return XCTFail() }
        XCTAssertEqual(german.name, "Entwürfe")
        XCTAssertEqual(german.rawName, "Entw&APw-rfe")
        guard case .untagged(.list(let parent)) = try parse("* LIST (\\Noselect \\HasChildren) NIL [Gmail]\r\n") else { return XCTFail() }
        XCTAssertNil(parent.delimiter)
        XCTAssertEqual(parent.name, "[Gmail]")
        XCTAssertFalse(parent.selectable)
        guard case .untagged(.list(let literal)) = try parse("* LIST () \"/\" {9}\r\nOdd\r\nName\r\n") else { return XCTFail() }
        XCTAssertEqual(literal.name, "Odd\r\nName")
    }

    func testFetchWithLiteralsFlagsAndGmailItems() throws {
        let header = "Subject: Hi\r\nFrom: Sam <sam@example.com>\r\n\r\n"
        let reply = "* 12 FETCH (UID 4827 FLAGS (\\Seen $Forwarded) INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 4286 "
            + "X-GM-MSGID 1278455344230334865 X-GM-THRID 1278455344230334865 X-GM-LABELS (\\Inbox \"Work stuff\") MODSEQ (12121231000) "
            + "BODY[HEADER.FIELDS (SUBJECT FROM)] {\(header.utf8.count)}\r\n\(header))\r\n"
        guard case .untagged(.fetch(let sequence, let fetch)) = try parse(reply) else { return XCTFail() }
        XCTAssertEqual(sequence, 12)
        XCTAssertEqual(fetch.uid, 4827)
        XCTAssertEqual(fetch.flags, ["\\Seen", "$Forwarded"])
        XCTAssertTrue(fetch.hasFlag("\\seen"))
        XCTAssertEqual(fetch.size, 4286)
        XCTAssertEqual(fetch.modSeq, 12_121_231_000)
        XCTAssertEqual(fetch.gmailMessageID, 1_278_455_344_230_334_865)
        XCTAssertEqual(fetch.gmailLabels, ["\\Inbox", "Work stuff"])
        XCTAssertEqual(fetch.internalDate, Date(timeIntervalSince1970: 837_596_665))
        XCTAssertEqual(fetch.header.map { String(decoding: $0, as: UTF8.self) }, header)
        XCTAssertEqual(Array(fetch.sections.keys), ["HEADER.FIELDS (SUBJECT FROM)"])
    }

    func testFetchWholeMessageAndNil() throws {
        guard case .untagged(.fetch(_, let body)) = try parse("* 1 FETCH (UID 9 BODY[] {5}\r\nHello)\r\n") else { return XCTFail() }
        XCTAssertEqual(body.message, Data("Hello".utf8))
        guard case .untagged(.fetch(_, let partial)) = try parse("* 1 FETCH (BODY[]<0> {3}\r\nabc UID 2)\r\n") else { return XCTFail() }
        XCTAssertEqual(partial.message, Data("abc".utf8))
        XCTAssertEqual(partial.uid, 2)
        guard case .untagged(.fetch(_, let empty)) = try parse("* 1 FETCH (UID 3 BODY[] NIL)\r\n") else { return XCTFail() }
        XCTAssertNil(empty.message)
        guard case .untagged(.fetch(_, let quoted)) = try parse("* 1 FETCH (UID 4 BODY[TEXT] \"say \\\"hi\\\"\")\r\n") else { return XCTFail() }
        XCTAssertEqual(quoted.sections["TEXT"], Data("say \"hi\"".utf8))
    }

    func testUIDOnlyReplies() throws {
        guard case .untagged(.fetch(let sequence, let data)) = try parse("* 25997 UIDFETCH (FLAGS (\\Flagged \\Answered))\r\n") else { return XCTFail() }
        XCTAssertEqual(sequence, 0)
        XCTAssertEqual(data.uid, 25997)
        XCTAssertEqual(data.flags, ["\\Flagged", "\\Answered"])
        guard case .untagged(.vanished(let earlier, let set)) = try parse("* VANISHED 405,407\r\n") else { return XCTFail() }
        XCTAssertFalse(earlier)
        XCTAssertEqual(set.numbers, [405, 407])
    }

    func testSearchReplies() throws {
        XCTAssertEqual(try parse("* SEARCH 2 84 882\r\n"), .untagged(.search([2, 84, 882], modSeq: nil)))
        XCTAssertEqual(try parse("* SEARCH\r\n"), .untagged(.search([], modSeq: nil)))
        XCTAssertEqual(try parse("* SEARCH 2 5 (MODSEQ 917162500)\r\n"), .untagged(.search([2, 5], modSeq: 917_162_500)))
        guard case .untagged(.esearch(let result)) = try parse("* ESEARCH (TAG \"J3\") UID ALL 1:3,7,10:11\r\n") else { return XCTFail() }
        XCTAssertTrue(result.uid)
        XCTAssertEqual(result.all?.numbers, [1, 2, 3, 7, 10, 11])
        guard case .untagged(.esearch(let counted)) = try parse("* ESEARCH (TAG \"J4\") UID MIN 7 MAX 3800 COUNT 12\r\n") else { return XCTFail() }
        XCTAssertEqual([counted.min, counted.max, counted.count], [7, 3800, 12])
        guard case .untagged(.vanished(let earlier, let set)) = try parse("* VANISHED (EARLIER) 41,43:45\r\n") else { return XCTFail() }
        XCTAssertTrue(earlier)
        XCTAssertEqual(set.numbers, [41, 43, 44, 45])
        guard case .untagged(.mailboxStatus(let name, let items)) = try parse("* STATUS \"Sent Items\" (MESSAGES 231 UIDNEXT 44292)\r\n") else { return XCTFail() }
        XCTAssertEqual(name, "Sent Items")
        XCTAssertEqual(items, ["MESSAGES": 231, "UIDNEXT": 44292])
    }

    func testRejectsBrokenReplies() {
        XCTAssertThrowsError(try parse("* 1 FETCH (UID 2\r\n"))
        XCTAssertThrowsError(try parse("* 1 FETCH (BODY[] {50}\r\nshort)\r\n"))
        XCTAssertThrowsError(try parse("J1 MAYBE fine\r\n"))
        let deep = "* 1 FETCH (X " + String(repeating: "(", count: 60) + String(repeating: ")", count: 60) + ")\r\n"
        XCTAssertThrowsError(try parse(deep))
    }

    // MARK: Framer

    func testFramerJoinsLiteralsAndSplitsReplies() throws {
        var framer = IMAPFramer()
        framer.append(Data("* 1 FETCH (UID 1 BODY[] {12}\r\nline\r\nline\r\n".utf8))
        XCTAssertNil(try framer.next())
        framer.append(Data(")\r\n* 2 EXISTS\r\nJ1 OK".utf8))
        XCTAssertEqual(try framer.next().map { String(decoding: $0, as: UTF8.self) }, "* 1 FETCH (UID 1 BODY[] {12}\r\nline\r\nline\r\n)\r\n")
        XCTAssertEqual(try framer.next().map { String(decoding: $0, as: UTF8.self) }, "* 2 EXISTS\r\n")
        XCTAssertNil(try framer.next())
        framer.append(Data(" done\r\n".utf8))
        XCTAssertEqual(try framer.next().map { String(decoding: $0, as: UTF8.self) }, "J1 OK done\r\n")
    }

    func testFramerHandlesALiteralThatEndsInBraces() throws {
        var framer = IMAPFramer()
        // The literal's own text ends in "{3}", which must not count as another literal.
        framer.append(Data("* 1 FETCH (BODY[] {5}\r\n{3}\r\n)\r\n".utf8))
        XCTAssertEqual(try framer.next()?.count, "* 1 FETCH (BODY[] {5}\r\n{3}\r\n)\r\n".utf8.count)
    }

    func testFramerLimitsSize() {
        var framer = IMAPFramer(maxReply: 100)
        framer.append(Data("* 1 FETCH (BODY[] {5000}\r\n".utf8))
        XCTAssertThrowsError(try framer.next())
    }

    // MARK: Commands

    func testCommandQuotingAndLiterals() {
        func wire(_ command: IMAPCommand, plus: Bool = true) -> [String] {
            command.segments(tag: "J1", literalPlus: plus).map { String(decoding: $0.data, as: UTF8.self) }
        }
        XCTAssertEqual(wire(IMAPCommand("SELECT").mailbox("inbox")), ["J1 SELECT INBOX\r\n"])
        XCTAssertEqual(wire(IMAPCommand("SELECT").mailbox("Sent Items")), ["J1 SELECT \"Sent Items\"\r\n"])
        XCTAssertEqual(wire(IMAPCommand("SELECT").mailbox("Entwürfe")), ["J1 SELECT Entw&APw-rfe\r\n"])
        XCTAssertEqual(wire(IMAPCommand("LIST").string("").string("*")), ["J1 LIST \"\" \"*\"\r\n"])
        XCTAssertEqual(wire(IMAPCommand("LOGIN").string("me@example.com").string("pa\"ss\\word")), ["J1 LOGIN me@example.com \"pa\\\"ss\\\\word\"\r\n"])
        // A value with a line break can never end the command line early.
        XCTAssertEqual(wire(IMAPCommand("LOGIN").string("me").string("a\r\nJ2 DELETE INBOX")), ["J1 LOGIN me {18+}\r\na\r\nJ2 DELETE INBOX\r\n"])
        let waiting = IMAPCommand("LOGIN").string("me").string("pässword").segments(tag: "J1", literalPlus: false)
        XCTAssertEqual(waiting.map(\.waitsForContinuation), [true, false])
        XCTAssertEqual(waiting.map { String(decoding: $0.data, as: UTF8.self) }, ["J1 LOGIN me {9}\r\n", "pässword\r\n"])
    }

    func testModifiedUTF7() {
        for name in ["INBOX", "Entwürfe", "A & B", "日本語", "Ünïcödé/Sub", "Emoji 📬"] {
            XCTAssertEqual(ModifiedUTF7.decode(ModifiedUTF7.encode(name)), name)
        }
        XCTAssertEqual(ModifiedUTF7.encode("A & B"), "A &- B")
        XCTAssertEqual(ModifiedUTF7.encode("~peter/mail/日本語/台北"), "~peter/mail/&ZeVnLIqe-/&U,BTFw-")
        XCTAssertEqual(ModifiedUTF7.decode("~peter/mail/&ZeVnLIqe-/&U,BTFw-"), "~peter/mail/日本語/台北")
        XCTAssertEqual(ModifiedUTF7.decode("Broken &ZeV"), "Broken &ZeV")
    }

    func testSequenceSets() {
        XCTAssertEqual(IMAPSequenceSet([5, 1, 2, 3, 9, 10]).description, "1:3,5,9:10")
        XCTAssertEqual(IMAPSequenceSet(parsing: "7:4,1")?.numbers, [1, 4, 5, 6, 7])
        XCTAssertNil(IMAPSequenceSet(parsing: "1:*"))
        XCTAssertEqual(IMAPSequenceSet(ranges: [1...1000]).count, 1000)
        let chunks = IMAPSequenceSet(ranges: [1...600]).chunked(maxCount: 250)
        XCTAssertEqual(chunks.map(\.description), ["351:600", "101:350", "1:100"])
        let scattered = IMAPSequenceSet(stride(from: UInt32(1), to: 2000, by: 2))
        let byLength = scattered.chunked(maxLength: 100)
        XCTAssertTrue(byLength.allSatisfy { $0.description.count <= 100 })
        XCTAssertEqual(byLength.reduce(0) { $0 + $1.count }, scattered.count)
        XCTAssertEqual(MailAccountSync.missing([1, 2, 3, 7, 9], from: IMAPSequenceSet([2, 3, 8, 9])), [1, 7])
        XCTAssertEqual(MailAccountSync.highest(IMAPSequenceSet([1, 2, 3, 10, 11]), count: 3), [3, 10, 11])
    }

    func testDates() {
        XCTAssertEqual(IMAPDate.parse(" 1-Jan-2000 00:00:00 +0000"), Date(timeIntervalSince1970: 946_684_800))
        XCTAssertEqual(IMAPDate.parse("29-Feb-2024 23:59:59 +0530"), Date(timeIntervalSince1970: 1_709_231_399))
        XCTAssertNil(IMAPDate.parse("31-Foo-2024 00:00:00 +0000"))
        let date = Date(timeIntervalSince1970: 1_790_000_123)
        XCTAssertEqual(IMAPDate.parse(IMAPDate.format(date)), date)
        XCTAssertEqual(MailComposer.rfc5322Date(Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!), "Thu, 1 Jan 1970 00:00:00 +0000")
        XCTAssertEqual(MailComposer.rfc5322Date(Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(secondsFromGMT: 3 * 3600)!),
                       "Mon, 21 Sep 2026 17:13:20 +0300")
    }
}
