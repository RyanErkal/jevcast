import XCTest
@testable import LauncherCore

final class FileSearchQueryTests: XCTestCase {
    func testFriendlyKindAndScopePhrase() {
        let query = FileSearchQuery.parse("pdfs in downloads")

        XCTAssertTrue(query.isValid)
        XCTAssertTrue(query.isExplicitFileSearch)
        XCTAssertEqual(query.kind, .pdf)
        XCTAssertEqual(query.scope, .downloads)
        XCTAssertEqual(query.nameQuery, "")
    }

    func testFriendlyDateAndFolderPhrase() {
        let date = FileSearchQuery.parse("files modified today")
        XCTAssertEqual(date.modified, .today)
        XCTAssertTrue(date.isExplicitFileSearch)
        XCTAssertEqual(date.nameQuery, "")

        let folder = FileSearchQuery.parse("find folder invoices")
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.nameQuery, "invoices")
        XCTAssertTrue(folder.isExplicitFileSearch)
    }

    func testQuotedPathAndExplicitPath() {
        let scoped = FileSearchQuery.parse("in:\"~/Work Files\" invoices")
        XCTAssertEqual(scoped.scopePath, "~/Work Files")
        XCTAssertEqual(scoped.nameQuery, "invoices")
        XCTAssertTrue(scoped.isExplicitFileSearch)

        let direct = FileSearchQuery.parse("\"/Users/example/Work Files/report.pdf\"")
        XCTAssertEqual(direct.explicitPath, "/Users/example/Work Files/report.pdf")
        XCTAssertTrue(direct.isExplicitFileSearch)

        let pasted = FileSearchQuery.parse("~/Downloads/Jev Launcher QA/notes.txt")
        XCTAssertEqual(pasted.explicitPath, "~/Downloads/Jev Launcher QA/notes.txt")
    }

    func testAppWordsAndWindowPhrasesStayNonExplicit() {
        for text in ["Photos", "open Photos", "Music", "open Music", "put window in left half", "move window from left to right"] {
            let query = FileSearchQuery.parse(text)
            XCTAssertFalse(query.isExplicitFileSearch, text)
        }
    }

    func testFilesAndRecentDownloadsAreExplicit() {
        let recent = FileSearchQuery.parse("recent downloads")
        XCTAssertTrue(recent.isExplicitFileSearch)
        XCTAssertEqual(recent.scope, .downloads)
        XCTAssertEqual(recent.nameQuery, "")

        let files = FileSearchQuery.parse("files modified today")
        XCTAssertTrue(files.isExplicitFileSearch)
    }

    func testQuotedNameKeepsStopWords() {
        let query = FileSearchQuery.parse("find \"The File\"")
        XCTAssertEqual(query.nameQuery, "The File")
        XCTAssertNil(query.kind)
    }

    func testInvalidFilterDoesNotBecomeANameQuery() {
        let query = FileSearchQuery.parse("kind:spreadsheet invoices")
        XCTAssertFalse(query.isValid)
        XCTAssertTrue(query.isExplicitFileSearch)
        XCTAssertEqual(query.nameQuery, "invoices")
        XCTAssertNotNil(query.validationError)
    }

    func testDateIntervalsUseInjectedCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = date("2026-09-23T14:30:00Z")

        let today = FileSearchQuery.parse("modified:today").modifiedInterval(now: now, calendar: calendar)
        XCTAssertEqual(today?.start, date("2026-09-23T00:00:00Z"))
        XCTAssertEqual(today?.end, date("2026-09-24T00:00:00Z"))

        let yesterday = FileSearchQuery.parse("modified:yesterday").modifiedInterval(now: now, calendar: calendar)
        XCTAssertEqual(yesterday?.start, date("2026-09-22T00:00:00Z"))

        let week = FileSearchQuery.parse("modified:week").modifiedInterval(now: now, calendar: calendar)
        XCTAssertEqual(week?.start, date("2026-09-21T00:00:00Z"))
    }

    func testKindAndNameFilters() {
        let query = FileSearchQuery.parse("pdf invoices")
        XCTAssertTrue(query.matches(
            name: "Invoices 2026.pdf",
            path: "/tmp/Invoices 2026.pdf",
            isDirectory: false,
            modifiedDate: date("2026-09-23T10:00:00Z")
        ))
        XCTAssertFalse(query.matches(
            name: "Invoices 2026.txt",
            path: "/tmp/Invoices 2026.txt",
            isDirectory: false,
            modifiedDate: date("2026-09-23T10:00:00Z")
        ))
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
