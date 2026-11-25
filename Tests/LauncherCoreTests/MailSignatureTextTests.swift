import XCTest
@testable import LauncherCore

/// The automatic signature's text, and the sidebar's status line.
final class MailSignatureTextTests: XCTestCase {
    func testASignatureGoesBelowABlankLine() {
        XCTAssertEqual(MailSignatureText.signed("", signature: "Alex"), "\n\nAlex", "A new message starts with room above it")
        XCTAssertEqual(MailSignatureText.signed("Hi Sam", signature: "Alex"), "Hi Sam\n\nAlex")
        XCTAssertEqual(MailSignatureText.signed("Hi Sam", signature: ""), "Hi Sam")
        XCTAssertEqual(MailSignatureText.clean("\n  Alex Morgan\nStudio \n\n"), "Alex Morgan\nStudio")
    }

    func testOnlyAnUnchangedSignatureComesOut() {
        XCTAssertEqual(MailSignatureText.typedPart(of: "Hi Sam\n\nAlex", signature: "Alex"), "Hi Sam")
        XCTAssertEqual(MailSignatureText.typedPart(of: "\n\nAlex", signature: "Alex"), "")
        XCTAssertEqual(MailSignatureText.typedPart(of: "Hi\n\n\nAlex", signature: "Alex"), "Hi\n", "Your own blank lines stay")
        XCTAssertNil(MailSignatureText.typedPart(of: "Hi Sam\n\nAlex M.", signature: "Alex"), "An edited signature is yours")
        XCTAssertNil(MailSignatureText.typedPart(of: "Hi Sam\n\nAlex\nP.S. Bring the agenda", signature: "Alex"), "Text after it keeps it")
        XCTAssertNil(MailSignatureText.typedPart(of: "Alex", signature: ""))
        XCTAssertNil(MailSignatureText.typedPart(of: "Please call Lee", signature: "Lee"), "Your own words that end like it are not the signature")
        XCTAssertNil(MailSignatureText.typedPart(of: "Lee", signature: "Lee"), "Without its blank line it is not the one Jevcast put in")
        let typed = "Ça va?"
        XCTAssertEqual(MailSignatureText.cursor(in: MailSignatureText.signed(typed, signature: "Alex"), signature: "Alex"), typed.utf16.count)
        XCTAssertNil(MailSignatureText.cursor(in: "Hi", signature: nil))
    }

    func testTheStatusLineSaysTheMostUsefulThing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ready = MailSyncStatusLine.Account(id: "a", state: .ready(now), lastSync: now.addingTimeInterval(-130))
        let older = MailSyncStatusLine.Account(id: "b", state: .ready(now), lastSync: now.addingTimeInterval(-3_600))
        XCTAssertEqual(MailSyncStatusLine.native([ready, older], online: true, checking: false, now: now)?.text, "Updated 2 min ago",
                       "The newest sync counts")
        XCTAssertEqual(MailSyncStatusLine.native([ready], online: true, checking: true, now: now)?.text, "Checking…")
        let syncing = MailSyncStatusLine.Account(id: "c", state: .syncing, lastSync: nil)
        XCTAssertEqual(MailSyncStatusLine.native([ready, syncing], online: true, checking: false, now: now)?.tone, .busy)
        let failed = MailSyncStatusLine.Account(id: "d", state: .failed("No", signIn: true), lastSync: nil)
        let review = MailSyncStatusLine.Account(id: "e", state: .ready(now), lastSync: now, needsReview: true)
        XCTAssertEqual(MailSyncStatusLine.native([ready, failed], online: true, checking: true, now: now),
                       MailSyncStatusLine(text: "1 account needs attention", tone: .attention, accountID: "d"))
        XCTAssertEqual(MailSyncStatusLine.native([review, failed], online: true, checking: false, now: now)?.text, "2 accounts need attention")
        XCTAssertEqual(MailSyncStatusLine.native([ready, failed], online: false, checking: false, now: now)?.text, "Offline",
                       "Offline is why every account stops")
        XCTAssertEqual(MailSyncStatusLine.native([MailSyncStatusLine.Account(id: "f", state: nil, lastSync: nil)], online: true, checking: false, now: now)?.text,
                       "Not checked yet")
        XCTAssertNil(MailSyncStatusLine.native([], online: true, checking: false, now: now))

        XCTAssertNil(MailSyncStatusLine.appleMail(running: true, checking: false, lastCheck: nil, now: now))
        XCTAssertNil(MailSyncStatusLine.appleMail(running: false, checking: false, lastCheck: now, now: now), "The list's note says Mail is closed")
        XCTAssertEqual(MailSyncStatusLine.appleMail(running: false, checking: true, lastCheck: nil, now: now)?.text, "Checking…")
        XCTAssertEqual(MailSyncStatusLine.appleMail(running: true, checking: false, lastCheck: now.addingTimeInterval(-20), now: now)?.text, "Updated just now")

        XCTAssertEqual(MailSyncStatusLine.updated(now.addingTimeInterval(-7_200), now: now), "Updated 2 hr ago")
        XCTAssertEqual(MailSyncStatusLine.updated(now.addingTimeInterval(-3 * 86_400), now: now), "Updated 3 days ago")
        XCTAssertEqual(MailSyncStatusLine.updated(now.addingTimeInterval(60), now: now), "Updated just now", "A clock change never shows a negative time")
    }
}
