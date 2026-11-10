import XCTest
import SwiftUI
@testable import JevLauncher

@MainActor
final class MailStyleTests: XCTestCase {
    func testAnAttachmentShowsAKindOfFileNotAMIMEType() {
        XCTAssertEqual(MailStyle.kind(mimeType: "application/pdf", filename: "Agenda.pdf"), "PDF document")
        XCTAssertEqual(MailStyle.kind(mimeType: "application/pdf", filename: "scan"), "PDF document", "The type names the file when its name does not.")
        XCTAssertEqual(MailStyle.kind(mimeType: "application/octet-stream", filename: "Budget.XLSX"), "Spreadsheet")
        XCTAssertEqual(MailStyle.kind(mimeType: "image/x-custom", filename: "photo.raw2"), "Image")
        XCTAssertEqual(MailStyle.kind(mimeType: "application/x-unknown-thing", filename: "data.zzq"), "ZZQ file")
        XCTAssertEqual(MailStyle.kind(mimeType: "application/x-unknown-thing", filename: "noextension"), "File")
    }

    func testInitialsComeFromTheFirstTwoWords() {
        XCTAssertEqual(MailStyle.initials("Sam Lee"), "SL")
        XCTAssertEqual(MailStyle.initials("accounts@example.com"), "AE")
        XCTAssertEqual(MailStyle.initials("Morgan"), "M")
        XCTAssertEqual(MailStyle.initials("  "), "?")
        XCTAssertEqual(MailStyle.initials("Jean-Luc van der Berg"), "JL")
    }

    func testSearchWordsAreMarkedWithoutChangingTheText() {
        let marked = MailStyle.highlighted("Friday at 10 works. See you friday.", words: "FRIDAY x")
        XCTAssertEqual(String(marked.characters), "Friday at 10 works. See you friday.")
        XCTAssertEqual(marked.runs.filter { $0.backgroundColor != nil }.count, 2, "Both places are marked, in any case.")
        XCTAssertEqual(MailStyle.highlighted("Plain", words: "").runs.filter { $0.backgroundColor != nil }.count, 0)
        // A one-letter word would mark half the text, so it marks nothing.
        XCTAssertEqual(MailStyle.highlighted("a banana", words: "a").runs.filter { $0.backgroundColor != nil }.count, 0)
    }

    func testOnlyAMessageOfPlainTextFollowsTheAppearance() {
        XCTAssertTrue(MailThreadHTML.isSimple("<div dir=\"ltr\">See you <b>Friday</b>.<br></div>"))
        XCTAssertFalse(MailThreadHTML.isSimple("<p style=\"color:#000\">Black text would vanish on a dark page.</p>"))
        XCTAssertFalse(MailThreadHTML.isSimple("<table><tr><td>Layout</td></tr></table>"))
        XCTAssertFalse(MailThreadHTML.isSimple("<img src=\"cid:logo\">"))
        XCTAssertFalse(MailThreadHTML.isSimple("<body bgcolor=\"#ffffff\">Hello</body>"))
        let plain = MailHTMLView.document("<div>Hello</div>")
        XCTAssertTrue(plain.contains("prefers-color-scheme:dark"), "A plain message follows dark appearance.")
        XCTAssertTrue(plain.contains("max-width:760px"), "Long lines stop at a width that reads well.")
        let designed = MailHTMLView.document("<table><tr><td style=\"background:#fff\">Offer</td></tr></table>")
        XCTAssertFalse(designed.contains("prefers-color-scheme"), "A designed message keeps the page its sender expected.")
    }

    func testAccountColorsAreSteady() {
        XCTAssertEqual(MailAccountMark.color(for: "acct-1"), MailAccountMark.color(for: "acct-1"))
        let mark = MailAccountMark(title: "alex@example.com", code: "AE", color: .blue)
        XCTAssertEqual(mark, MailAccountMark(title: "alex@example.com", code: "AE", color: .blue))
    }

    func testEachAccountHasItsOwnShortCode() {
        let codes = MailSidebarAccounts.codes([(id: "a", address: "sam.lee@gmail.com"), (id: "b", address: "sam@acme.example"),
            (id: "c", address: "morgan@gmail.com"), (id: "d", address: "x@icloud.com")])
        XCTAssertEqual(codes, ["a": "SL", "b": "SA", "c": "MO", "d": "XI"])
        // The same two letters: the later account gets a third, and no two codes match.
        let same = MailSidebarAccounts.codes([(id: "a", address: "sam@acme.example"), (id: "b", address: "sam@apex.example"),
            (id: "c", address: "sam@acme.example"), (id: "d", address: "sa@gmail.com"), (id: "e", address: "")])
        XCTAssertEqual(same["a"], "SA")
        XCTAssertEqual(same["b"], "SAA")
        XCTAssertEqual(Set(same.values).count, 5)
        XCTAssertTrue(same.values.allSatisfy { (2...3).contains($0.count) })
        let many = MailSidebarAccounts.codes((0..<30).map { (id: String(format: "%02d", $0), address: "sam@acme.example") })
        XCTAssertEqual(Set(many.values).count, 30)
    }
}
