import XCTest
@testable import LauncherCore

final class MailLinksTests: XCTestCase {
    func testMailtoReadsAddressesSubjectAndBody() throws {
        let link = try XCTUnwrap(MailtoLink("mailto:sam@example.com,%20alex@example.com?cc=team@example.com&subject=Hello%20there&body=Line%201%0D%0ALine%202&attach=/etc/passwd"))
        XCTAssertEqual(link.to, ["sam@example.com", "alex@example.com"])
        XCTAssertEqual(link.cc, ["team@example.com"]); XCTAssertEqual(link.bcc, [])
        XCTAssertEqual(link.subject, "Hello there"); XCTAssertEqual(link.body, "Line 1\nLine 2")
        XCTAssertEqual(MailtoLink(URL(string: "MAILTO:sam@example.com")!)?.to, ["sam@example.com"])
    }

    func testMailtoRefusesOtherLinksAndBrokenAddresses() {
        XCTAssertNil(MailtoLink("https://example.com"))
        XCTAssertNil(MailtoLink("mailto:"))
        XCTAssertNil(MailtoLink("mailto:not-an-address"))
        XCTAssertEqual(MailtoLink("mailto:?subject=Only%20a%20subject")?.subject, "Only a subject")
        // A line break in a subject cannot add a header.
        XCTAssertEqual(MailtoLink("mailto:a@example.com?subject=Hi%0D%0ABcc:%20x@example.com")?.subject, "Hi  Bcc: x@example.com")
        XCTAssertEqual(MailtoLink("mailto:a@example.com%0Ab@example.com")?.to ?? [], [])
    }

    func testUnsubscribeHeaderOffersMailAndASecureWebPage() throws {
        let both = try XCTUnwrap(MailUnsubscribe(header: "<mailto:leave@list.example.com?subject=unsubscribe>, <https://list.example.com/u/123>"))
        XCTAssertEqual(both.mail?.to, ["leave@list.example.com"]); XCTAssertEqual(both.mail?.subject, "unsubscribe")
        XCTAssertEqual(both.web?.host, "list.example.com")
        XCTAssertNil(MailUnsubscribe(header: "<http://list.example.com/u/123>"), "A page without TLS is not offered.")
        XCTAssertNil(MailUnsubscribe(header: "<https://user:pass@list.example.com/u>"))
        XCTAssertNil(MailUnsubscribe(header: nil)); XCTAssertNil(MailUnsubscribe(header: "leave@list.example.com"))
        // A folded header has spaces inside the address.
        XCTAssertEqual(MailUnsubscribe(header: "<https://list.example.com/u/\r\n 123>")?.web?.path, "/u/123")
    }

    func testFolderNamesAreSingleSafeNames() throws {
        XCTAssertEqual(try MailAccountSync.folderName("  Clients ", delimiter: "/"), "Clients")
        XCTAssertThrowsError(try MailAccountSync.folderName("", delimiter: "/"))
        XCTAssertThrowsError(try MailAccountSync.folderName("A/B", delimiter: "/"))
        XCTAssertEqual(try MailAccountSync.folderName("A/B", delimiter: "."), "A/B")
        XCTAssertThrowsError(try MailAccountSync.folderName("All*", delimiter: "/"))
        XCTAssertThrowsError(try MailAccountSync.folderName("Line\nbreak", delimiter: "/"))
        XCTAssertThrowsError(try MailAccountSync.folderName(String(repeating: "a", count: 121), delimiter: "/"))
    }
}
