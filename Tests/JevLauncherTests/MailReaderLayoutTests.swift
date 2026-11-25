import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailReaderLayoutTests: XCTestCase {
    func testShortDatesFollowTheListRule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 15))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 8))!
        let lastWeek = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 12, day: 30, hour: 9))!
        XCTAssertEqual(MailDates.style(for: morning, now: now, calendar: calendar), .time, "Today shows the time")
        XCTAssertEqual(MailDates.style(for: lastWeek, now: now, calendar: calendar), .dayMonth, "This year shows the day and month")
        XCTAssertEqual(MailDates.style(for: lastYear, now: now, calendar: calendar), .numeric, "Older mail shows the numeric date")
        XCTAssertEqual(MailRow.date(Date()), MailDates.short(Date()), "The list and the reader agree")
        XCTAssertGreaterThan(MailDates.full(lastWeek).count, MailDates.short(lastWeek, now: now, calendar: calendar).count)
    }

    func testTheToolbarHasAtMostSevenControlsInOrder() {
        let all = MailReaderToolbarItem.items(canSnooze: true, canExpand: true)
        XCTAssertEqual(all, [.archive, .delete, .reply, .readToggle, .snooze, .more, .expand])
        XCTAssertEqual(MailReaderToolbarItem.items(canSnooze: false, canExpand: true),
                       [.archive, .delete, .reply, .readToggle, .more, .expand])
        XCTAssertEqual(MailReaderToolbarItem.items(canSnooze: false, canExpand: false), [.archive, .delete, .reply, .readToggle, .more])
    }

    func testEveryToolbarControlHasALabelAndATooltipWithItsKey() {
        for item in MailReaderToolbarItem.allCases {
            XCTAssertFalse(item.title.isEmpty)
            if item != .more { XCTAssertTrue(item.help().contains("("), "\(item) names its key") }
        }
        XCTAssertTrue(MailReaderToolbarItem.reply.help().contains("⇧⌘R"), "Reply All is offered with its key")
        XCTAssertTrue(MailReaderToolbarItem.reply.help().contains("⇧⌘F"))
        XCTAssertEqual(MailReaderToolbarItem.expand.help(expanded: true), "Show the list (Escape)")
    }

    func testTheReaderDocumentsDrawOnThePaneSurface() {
        let simple = MailHTMLView.document("<div>Hello</div>", surface: .message)
        XCTAssertTrue(simple.contains("background:transparent"), "Text mail shows the pane behind it")
        XCTAssertFalse(simple.contains("#1c1c1e"))
        XCTAssertTrue(simple.contains("prefers-color-scheme:dark"), "Its text follows dark appearance")
        XCTAssertEqual(MailHTMLView.readerSurface("<div>Hello</div>"), .message)
        let thread = MailHTMLView.document(MailThreadHTML.render([], prefersPlain: false), surface: .thread)
        XCTAssertFalse(thread.contains("prefers-color-scheme:dark){:where(body){background"))
        XCTAssertTrue(MailThreadHTML.style.contains("html,body{background:transparent!important}"))
        XCTAssertFalse(MailThreadHTML.style.contains("#1c1c1e"))
    }

    func testADesignedMessageKeepsItsOwnPageColours() {
        // A dark page with light text on the root element, as some newsletters send.
        let dark = "<html style=\"background:#14171f;color:#e9e4da\"><body><table><tr><td>Offer</td></tr></table></body></html>"
        XCTAssertEqual(MailHTMLView.readerSurface(dark), .card, "Mail with its own colours is a card")
        XCTAssertEqual(MailHTMLView.readerSurface(MailSnapshots.designedMessage()), .card)
        for fits in [true, false] {
            let document = MailHTMLView.document(dark, fitsWidth: fits, surface: .card)
            XCTAssertTrue(document.contains("background:#14171f;color:#e9e4da"), "The sender's page stays")
            // Nothing Jevcast adds sets the page's colours: the card is the view, not the mail.
            let added = document.replacingOccurrences(of: dark, with: "")
            XCTAssertFalse(added.contains("background"), "No page colour is added")
            XCTAssertFalse(added.range(of: #"(html|body)[^{}]*\{[^}]*color"#, options: .regularExpression) != nil)
            XCTAssertFalse(added.contains("border-radius"), "Round corners belong to the view")
            XCTAssertFalse(added.contains("prefers-color-scheme"), "A designed message does not follow dark appearance")
        }
        // A page outside the reader, such as a quote in the composer, has no reader styles either.
        XCTAssertFalse(MailHTMLView.document("<table></table>").contains("transparent"))
    }

    func testReplyInitialsUseTheAvatarColours() {
        XCTAssertEqual(MailThreadHTML.avatarColor("Sam@Example.com"), MailThreadHTML.avatarColor("sam@example.com"))
        let index = MailAvatar.paletteIndex(for: "sam@example.com")
        XCTAssertTrue((0..<10).contains(index))
        let html = MailThreadHTML.render([.init(message: .init(rowID: 7, mailbox: 1, subject: "Plan", senderName: "Sam Lee",
            senderAddress: "sam@example.com", snippet: "Hi", date: Date(), read: true, flagged: false, conversation: 1), body: nil)],
            prefersPlain: false, pick: "jev-test-")
        XCTAssertTrue(html.contains(">SL</span>"))
        XCTAssertTrue(html.contains("id=\"jev-test-7\" class=\"jev-message\""))
        XCTAssertTrue(MailThreadHTML.mark(7, pick: "jev-test-").contains("#jev-test-7{"), "The mark names the reply by its anchor")
        XCTAssertTrue(html.contains("href=\"#jev-test-7\""))
        XCTAssertFalse(html.contains("jevcast-message:"))
    }
}
