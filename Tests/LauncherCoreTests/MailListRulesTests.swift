import XCTest
@testable import LauncherCore

/// The list's pure rules: date labels, what a row's menu offers, and the one-click filters.
final class MailListRulesTests: XCTestCase {
    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar(firstWeekday: 2).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: Date sections

    func testSectionsFollowTheDayTheWeekTheMonthAndTheYear() {
        // Wednesday 25 November 2026; the week starts on Monday 23 November.
        let now = date(2026, 11, 25), monday = calendar(firstWeekday: 2)
        func section(_ day: Date) -> MailDateSection { MailDateSections.section(for: day, now: now, calendar: monday) }
        XCTAssertEqual(section(date(2026, 11, 25, 0)), .today)
        XCTAssertEqual(section(date(2026, 11, 26)), .today, "A date ahead of the clock counts as today")
        XCTAssertEqual(section(date(2026, 11, 24, 23)), .yesterday)
        XCTAssertEqual(section(date(2026, 11, 23, 1)), .thisWeek)
        XCTAssertEqual(section(date(2026, 11, 22)), .lastWeek)
        XCTAssertEqual(section(date(2026, 11, 16, 0)), .lastWeek)
        XCTAssertEqual(section(date(2026, 11, 15, 23)), .month(11))
        XCTAssertEqual(section(date(2026, 10, 3)), .month(10))
        XCTAssertEqual(section(date(2026, 1, 1)), .month(1))
        XCTAssertEqual(section(date(2025, 12, 31)), .year(2025))
    }

    func testTheWeekStartsOnTheCalendarsOwnFirstDay() {
        let now = date(2026, 11, 25)
        let sunday = calendar(firstWeekday: 1), monday = calendar(firstWeekday: 2)
        XCTAssertEqual(MailDateSections.section(for: date(2026, 11, 22), now: now, calendar: sunday), .thisWeek)
        XCTAssertEqual(MailDateSections.section(for: date(2026, 11, 22), now: now, calendar: monday), .lastWeek)
    }

    func testYesterdayComesBeforeLastWeekOnTheWeeksFirstDay() {
        let now = date(2026, 11, 23)
        XCTAssertEqual(MailDateSections.section(for: date(2026, 11, 22), now: now, calendar: calendar(firstWeekday: 2)), .yesterday)
    }

    func testTitlesAreShortWords() {
        let calendar = calendar(firstWeekday: 2)
        XCTAssertEqual(MailDateSection.today.title(calendar: calendar), "Today")
        XCTAssertEqual(MailDateSection.yesterday.title(calendar: calendar), "Yesterday")
        XCTAssertEqual(MailDateSection.thisWeek.title(calendar: calendar), "This Week")
        XCTAssertEqual(MailDateSection.lastWeek.title(calendar: calendar), "Last Week")
        XCTAssertEqual(MailDateSection.month(10).title(calendar: calendar), "October")
        XCTAssertEqual(MailDateSection.year(2025).title(calendar: calendar), "2025")
    }

    func testStartsMarkTheFirstRowOfEachSection() {
        let now = date(2026, 11, 25), monday = calendar(firstWeekday: 2)
        let dates = [date(2026, 11, 25, 10), date(2026, 11, 25, 9), date(2026, 11, 24), date(2026, 11, 23),
                     date(2026, 11, 20), date(2026, 11, 17), date(2026, 10, 30), date(2026, 10, 2), date(2025, 6, 1)]
        XCTAssertEqual(MailDateSections.starts(dates, now: now, calendar: monday),
                       [0: .today, 2: .yesterday, 3: .thisWeek, 4: .lastWeek, 6: .month(10), 8: .year(2025)])
    }

    func testShortOrUnsortedListsHaveNoSections() {
        let now = date(2026, 11, 25), monday = calendar(firstWeekday: 2)
        let short = (0..<7).map { date(2026, 11, 25 - $0) }
        XCTAssertEqual(MailDateSections.starts(short, now: now, calendar: monday), [:])
        let ranked = (0..<10).map { date(2026, 11, 25 - $0) }.reversed()
        XCTAssertEqual(MailDateSections.starts(Array(ranked), now: now, calendar: monday), [:], "Results ranked another way have no labels")
        let long = (0..<8).map { date(2026, 11, 25 - $0) }
        XCTAssertFalse(MailDateSections.starts(long, now: now, calendar: monday).isEmpty)
    }

    // MARK: Row menu

    func testAnInboxRowOffersEveryAction() {
        let context = MailRowMenuContext(roles: [.inbox], canSnooze: true)
        XCTAssertEqual(MailRowMenu.groups(context), [[.reply, .replyAll, .forward], [.archive, .readToggle, .flagToggle, .snooze, .move],
                                                    [.junkToggle, .delete, .deleteAllFromSender]])
        XCTAssertFalse(MailRowMenu.actions(MailRowMenuContext(roles: [.inbox])).contains(.snooze), "Snooze only for Jevcast accounts")
        XCTAssertFalse(MailRowMenu.actions(MailRowMenuContext(roles: [.inbox], canMove: false)).contains(.move))
    }

    func testSeveralRowsDropWhatActsOnOneMessage() {
        let context = MailRowMenuContext(roles: [.inbox], multiple: true, canSnooze: true)
        XCTAssertEqual(MailRowMenu.groups(context), [[.archive, .readToggle, .flagToggle, .move], [.delete]])
    }

    func testEachMailboxOffersOnlyWhatItSupports() {
        XCTAssertEqual(MailRowMenu.groups(.init(roles: [.drafts], native: true)), [[.editDraft], [.flagToggle, .move], [.delete]])
        XCTAssertEqual(MailRowMenu.groups(.init(roles: [.drafts])), [[.flagToggle, .move], [.delete]])
        XCTAssertEqual(MailRowMenu.groups(.init(roles: [.sent], canSnooze: true)),
                       [[.reply, .replyAll, .forward], [.archive, .readToggle, .flagToggle, .move], [.delete]])
        XCTAssertEqual(MailRowMenu.groups(.init(roles: [.trash], canSnooze: true)),
                       [[.reply, .replyAll, .forward], [.readToggle, .flagToggle, .move], [.delete]])
        XCTAssertEqual(MailRowMenu.groups(.init(roles: [.junk], canSnooze: true)),
                       [[.readToggle, .flagToggle, .move], [.junkToggle, .delete, .deleteAllFromSender]])
        XCTAssertEqual(MailRowMenu.groups(.init(roles: [.archive])),
                       [[.reply, .replyAll, .forward], [.readToggle, .flagToggle, .move], [.junkToggle, .delete, .deleteAllFromSender]])
    }

    func testSeveralRowsInTrashCannotBeDeletedTogether() {
        // In Trash a delete is permanent and goes one message at a time.
        XCTAssertFalse(MailRowMenu.actions(.init(roles: [.trash], multiple: true)).contains(.delete))
        XCTAssertFalse(MailRowMenu.actions(.init(roles: [.inbox, .trash], multiple: true)).contains(.delete))
        XCTAssertFalse(MailRowMenu.actions(.init(roles: [.inbox, .junk], multiple: true)).contains(.archive), "Every row must allow it")
    }

    func testRowsOfNoKnownMailboxOfferNothing() {
        XCTAssertEqual(MailRowMenu.groups(.init(roles: [])), [])
    }

    func testHoverAndBulkActionsFollowTheMenusRules() {
        XCTAssertEqual(MailRowMenu.hoverActions(.init(roles: [.inbox])), [.archive, .delete, .readToggle])
        XCTAssertEqual(MailRowMenu.hoverActions(.init(roles: [.drafts])), [.delete])
        XCTAssertEqual(MailRowMenu.hoverActions(.init(roles: [.trash])), [.delete, .readToggle])
        XCTAssertEqual(MailRowMenu.bulkActions(.init(roles: [.inbox])), [.archive, .delete, .readToggle, .flagToggle, .move])
        XCTAssertEqual(MailRowMenu.bulkActions(.init(roles: [.trash], canMove: false)), [.readToggle, .flagToggle])
    }

    func testMenuItemsShowTheReadersKeys() {
        XCTAssertEqual(MailRowAction.archive.key, "⌘E")
        XCTAssertEqual(MailRowAction.delete.key, "⌫")
        XCTAssertEqual(MailRowAction.snooze.key, "⌃⌘S")
        XCTAssertNil(MailRowAction.deleteAllFromSender.key)
    }

    // MARK: Filter chips

    func testChipsSetTheFormsFieldsAndKeepTheRest() {
        let form = MailFilter(from: "sam", flaggedOnly: true)
        let unread = MailFilterChip.unread.toggled(form)
        XCTAssertTrue(unread.unreadOnly)
        XCTAssertEqual(unread.from, "sam")
        XCTAssertTrue(MailFilterChip.flagged.isOn(unread))
        XCTAssertFalse(MailFilterChip.flagged.isOn(MailFilterChip.flagged.toggled(unread)))
        XCTAssertTrue(MailFilterChip.attachments.toggled(MailFilter()).attachmentsOnly)
        XCTAssertEqual(MailFilterChip.unread.toggled(unread), form, "A second click turns the chip off again")
    }

    func testTheOtherCountLeavesOutTheChips() {
        XCTAssertEqual(MailFilterChip.otherCount(MailFilter()), 0)
        XCTAssertEqual(MailFilterChip.otherCount(MailFilter(unreadOnly: true, flaggedOnly: true)), 0)
        XCTAssertEqual(MailFilterChip.otherCount(MailFilter(from: "sam", dateFrom: Date(), unreadOnly: true)), 2)
    }
}
