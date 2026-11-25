import XCTest
@testable import LauncherCore

/// Mail's column widths, with and without widths you dragged to, and the sidebar's short counts.
final class MailColumnLayoutTests: XCTestCase {
    private let widths = [860.0, 980.0, 1320.0]

    func testDefaultsFollowThePanel() {
        let smallest = MailColumnLayout.resolve(total: 860, showsSidebar: true, listFraction: 0.36)
        XCTAssertEqual(smallest.sidebar, 190)
        XCTAssertEqual(smallest.list, 241)
        XCTAssertEqual(smallest.reader, 427)
        let largest = MailColumnLayout.resolve(total: 1320, showsSidebar: true, listFraction: 0.26)
        XCTAssertEqual(largest.sidebar, 205)
        XCTAssertEqual(largest.list, 290, "Wider message: a quarter of what the sidebar leaves")
        let hidden = MailColumnLayout.resolve(total: 980, showsSidebar: false, listFraction: 0.36)
        XCTAssertEqual(hidden.sidebar, 0)
        XCTAssertEqual(hidden.reader, 980 - hidden.list - 1, "One divider without the sidebar")
    }

    func testADraggedWidthReplacesTheDefault() {
        let layout = MailColumnLayout.resolve(total: 1320, showsSidebar: true, listFraction: 0.36, customSidebar: 250, customList: 470)
        XCTAssertEqual(layout.sidebar, 250)
        XCTAssertEqual(layout.list, 470)
        XCTAssertEqual(layout.reader, 1320 - 250 - 470 - 2)
    }

    func testTheReaderNeverGetsNarrowerThanItsMinimum() {
        for total in widths {
            for sidebar in [nil, 0.0, 100, 250, 5_000] as [Double?] {
                for list in [nil, 0.0, 300, 600, 5_000] as [Double?] {
                    for shows in [true, false] {
                        let layout = MailColumnLayout.resolve(total: total, showsSidebar: shows, listFraction: 0.36,
                                                              customSidebar: sidebar, customList: list)
                        XCTAssertGreaterThanOrEqual(layout.reader, MailColumnLayout.readerMinimum, "\(total) \(String(describing: sidebar)) \(String(describing: list))")
                        XCTAssertTrue(MailColumnLayout.listRange.contains(layout.list))
                        if shows { XCTAssertTrue(MailColumnLayout.sidebarRange.contains(layout.sidebar)) }
                    }
                }
            }
        }
    }

    func testDraggingClampsToTheRange() {
        XCTAssertEqual(MailColumnLayout.clampSidebar(40, total: 1320), 160, "Never narrower than its minimum")
        XCTAssertEqual(MailColumnLayout.clampSidebar(900, total: 1320), 320, "Never wider than its maximum")
        XCTAssertEqual(MailColumnLayout.clampSidebar(300, total: 860), 198, "At 860 the reader keeps its room")
        XCTAssertEqual(MailColumnLayout.clampList(900, total: 1320, sidebar: 205), 560)
        XCTAssertEqual(MailColumnLayout.clampList(900, total: 860, sidebar: 190), 248)
        XCTAssertEqual(MailColumnLayout.clampList(300.4, total: 1320, sidebar: 205), 300, "Whole points")
    }

    func testLargeCountsAreShort() {
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(MailBadgeCount.text(7, locale: locale), "7")
        XCTAssertEqual(MailBadgeCount.text(9_999, locale: locale), "9,999")
        XCTAssertEqual(MailBadgeCount.text(10_000, locale: locale), "10K")
        XCTAssertEqual(MailBadgeCount.text(33_009, locale: locale), "33K")
        XCTAssertEqual(MailBadgeCount.text(999_999, locale: locale), "999K", "Rounded down, never more than there is")
        XCTAssertEqual(MailBadgeCount.text(1_000_000, locale: locale), "1M")
        XCTAssertEqual(MailBadgeCount.text(1_290_000, locale: locale), "1.2M")
        XCTAssertEqual(MailBadgeCount.text(12_500_000, locale: locale), "12M")
    }
}
