import XCTest
@testable import LauncherCore

final class CalendarInviteTests: XCTestCase {
    private let request = """
    BEGIN:VCALENDAR\r
    PRODID:-//Example//EN\r
    VERSION:2.0\r
    METHOD:REQUEST\r
    BEGIN:VTIMEZONE\r
    TZID:Europe/London\r
    BEGIN:STANDARD\r
    DTSTART:19701025T020000\r
    END:STANDARD\r
    END:VTIMEZONE\r
    BEGIN:VEVENT\r
    UID:event-123@example.com\r
    SEQUENCE:2\r
    DTSTART;TZID=Europe/London:20261110T093000\r
    DTEND;TZID=Europe/London:20261110T101500\r
    SUMMARY:Design review\\, part 2\r
    LOCATION:Room 4\\; second floor\r
    DESCRIPTION:Agenda\\nFirst item with a long line that is folded here so that the parser\r
      must join it again\r
    ORGANIZER;CN="Taylor, Sam":mailto:sam@example.com\r
    ATTENDEE;CN=Alex Morgan;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:Alex@Example.com\r
    ATTENDEE;CN=Jamie;PARTSTAT=ACCEPTED:mailto:jamie@example.com\r
    BEGIN:VALARM\r
    ACTION:DISPLAY\r
    DESCRIPTION:Reminder\r
    END:VALARM\r
    END:VEVENT\r
    END:VCALENDAR\r

    """

    private func london(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
    }

    func testReadsARequestWithFoldedLinesEscapesAndQuotedNames() throws {
        let invite = try XCTUnwrap(CalendarInvite.parse(request))
        XCTAssertEqual(invite.method, .request)
        XCTAssertEqual(invite.uid, "event-123@example.com")
        XCTAssertEqual(invite.title, "Design review, part 2")
        XCTAssertEqual(invite.location, "Room 4; second floor")
        XCTAssertEqual(invite.notes, "Agenda\nFirst item with a long line that is folded here so that the parser must join it again")
        XCTAssertEqual(invite.start, london(9, 30)); XCTAssertEqual(invite.end, london(10, 15))
        XCTAssertFalse(invite.allDay); XCTAssertEqual(invite.sequence, 2); XCTAssertFalse(invite.recurring)
        XCTAssertEqual(invite.organizer, .init(name: "Taylor, Sam", address: "sam@example.com", status: ""))
        XCTAssertEqual(invite.attendees.map(\.address), ["Alex@Example.com", "jamie@example.com"])
        XCTAssertEqual(invite.attendee(among: ["other@example.com", "alex@example.com"])?.status, "NEEDS-ACTION")
        XCTAssertTrue(invite.canReply)
        XCTAssertEqual(invite.timeZone, "Europe/London")
    }

    func testAlarmTextIsNotTheEventsText() throws {
        let invite = try XCTUnwrap(CalendarInvite.parse(request))
        XCTAssertFalse(invite.notes.contains("Reminder"))
    }

    func testReplyEchoesTheEventAndNamesOnlyTheAnsweringGuest() throws {
        let invite = try XCTUnwrap(CalendarInvite.parse(request))
        let reply = invite.reply(.accepted, from: "alex@example.com", name: "Alex \"A\" Morgan", now: Date(timeIntervalSince1970: 1_794_300_000))
        XCTAssertTrue(reply.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(reply.contains("METHOD:REPLY\r\n"))
        XCTAssertTrue(reply.contains("UID:event-123@example.com\r\n"))
        XCTAssertTrue(reply.contains("SEQUENCE:2\r\n"))
        XCTAssertTrue(reply.contains("DTSTART;TZID=Europe/London:20261110T093000\r\n"))
        XCTAssertTrue(reply.contains("ORGANIZER;CN=\"Taylor, Sam\":mailto:sam@example.com\r\n"))
        XCTAssertTrue(reply.contains("ATTENDEE;PARTSTAT=ACCEPTED;CN=\"Alex 'A' Morgan\":mailto:alex@example.com\r\n"))
        XCTAssertFalse(reply.contains("jamie@example.com"), "Other guests are not part of a reply.")
        XCTAssertTrue(reply.hasSuffix("END:VEVENT\r\nEND:VCALENDAR\r\n"))
        XCTAssertTrue(reply.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        // The reply reads back as a reply to the same event.
        let read = try XCTUnwrap(CalendarInvite.parse(reply))
        XCTAssertEqual(read.method, .reply); XCTAssertEqual(read.uid, invite.uid); XCTAssertEqual(read.start, invite.start)
        XCTAssertEqual(read.attendees.first?.status, "ACCEPTED")
        XCTAssertEqual(invite.replySubject(.declined), "Declined: Design review, part 2")
    }

    func testAReplyValueCannotStartAnotherProperty() throws {
        let invite = try XCTUnwrap(CalendarInvite.parse(request))
        let reply = invite.reply(.declined, from: "alex@example.com\r\nATTENDEE:mailto:evil@example.com", name: "A\r\nMETHOD:CANCEL")
        XCTAssertEqual(reply.components(separatedBy: "\r\n").filter { $0.hasPrefix("ATTENDEE") }.count, 1)
        XCTAssertEqual(reply.components(separatedBy: "\r\n").filter { $0.hasPrefix("METHOD") }, ["METHOD:REPLY"])
    }

    func testAllDayUtcDurationAndWindowsZones() throws {
        let allDay = try XCTUnwrap(CalendarInvite.parse("BEGIN:VCALENDAR\nMETHOD:PUBLISH\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20261224\nDTEND;VALUE=DATE:20261226\nRRULE:FREQ=YEARLY\nEND:VEVENT\nEND:VCALENDAR"))
        XCTAssertTrue(allDay.allDay); XCTAssertTrue(allDay.recurring); XCTAssertFalse(allDay.canReply)
        XCTAssertEqual(allDay.end.timeIntervalSince(allDay.start), 2 * 86_400, accuracy: 3700)
        let utc = try XCTUnwrap(CalendarInvite.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:b\nDTSTART:20261110T083000Z\nDURATION:PT1H30M\nEND:VEVENT\nEND:VCALENDAR"))
        XCTAssertEqual(utc.start, Date(timeIntervalSince1970: 1_794_299_400))
        XCTAssertEqual(utc.end.timeIntervalSince(utc.start), 5400)
        let outlook = try XCTUnwrap(CalendarInvite.parse("BEGIN:VCALENDAR\nMETHOD:REQUEST\nBEGIN:VEVENT\nUID:c\nDTSTART;TZID=\"GMT Standard Time\":20261110T093000\nDTEND;TZID=\"GMT Standard Time\":20261110T100000\nEND:VEVENT\nEND:VCALENDAR"))
        XCTAssertEqual(outlook.start, london(9, 30))
        XCTAssertFalse(outlook.canReply, "A request with no organizer has nobody to answer.")
    }

    func testRefusesTextWithoutAnEventOrIdentity() {
        XCTAssertNil(CalendarInvite.parse(""))
        XCTAssertNil(CalendarInvite.parse("BEGIN:VCALENDAR\nMETHOD:REQUEST\nEND:VCALENDAR"))
        XCTAssertNil(CalendarInvite.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20261110T083000Z\nEND:VEVENT\nEND:VCALENDAR"))
        XCTAssertNil(CalendarInvite.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nDTSTART:not-a-date\nEND:VEVENT\nEND:VCALENDAR"))
        XCTAssertNil(CalendarInvite.person("mailto:two words@example.com", [:]))
        XCTAssertNil(CalendarInvite.person("https://example.com", [:]))
        XCTAssertNil(CalendarInvite.duration("-PT1H"))
    }

    func testAMessageKeepsItsInvitationTextAndAReplyGoesAsACalendarPart() throws {
        let raw = "From: sam@example.com\r\nSubject: Invitation\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"b\"\r\n\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\nYou are invited.\r\n"
            + "--b\r\nContent-Type: text/calendar; method=REQUEST; charset=utf-8\r\n\r\n" + request + "\r\n--b--\r\n"
        let message = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        XCTAssertEqual(message.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "You are invited.")
        let invite = try XCTUnwrap(message.calendarText.flatMap(CalendarInvite.parse))
        XCTAssertEqual(invite.uid, "event-123@example.com")
        XCTAssertTrue(message.attachments.isEmpty, "An inline invitation is not a file.")

        var out = OutgoingMessage(from: MailContact(address: "alex@example.com"), to: [MailContact(address: "sam@example.com")],
                                  subject: invite.replySubject(.accepted), body: "Alex accepted.")
        out.calendarReply = invite.reply(.accepted, from: "alex@example.com")
        let sent = try XCTUnwrap(MIMEMessage.parse(MailComposer.render(out)))
        let text = String(decoding: MailComposer.render(out), as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: text/calendar; charset=utf-8; method=REPLY"))
        XCTAssertEqual(sent.calendarText.flatMap(CalendarInvite.parse)?.method, .reply)
        XCTAssertEqual(sent.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Alex accepted.")
    }
}
