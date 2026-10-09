import XCTest
import LauncherCore
@testable import JevLauncher

final class MailRecipientTests: XCTestCase {
    func testParserKeepsDisplayNamesAndSeparatesQuotedCommas() {
        let values = MailRecipientParser.parse(#""Smith, Ann" <ann@example.com>; bob@example.com"#)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].recipient?.name, "Smith, Ann")
        XCTAssertEqual(values[0].recipient?.address, "ann@example.com")
        XCTAssertEqual(values[1].recipient?.address, "bob@example.com")
        XCTAssertEqual(MailRecipientParser.normalize(#""Smith, Ann" <ann@example.com>; bob@example.com"#),
                       #""Smith, Ann" <ann@example.com>, bob@example.com"#)
    }

    func testInvalidRecipientStaysVisibleAndIsReported() {
        let values = MailRecipientParser.parse("good@example.com, unfinished")
        XCTAssertTrue(values[0].isValid)
        XCTAssertFalse(values[1].isValid)
        XCTAssertEqual(MailRecipientParser.problem("good@example.com, unfinished", required: true),
                       "“unfinished” is not an email address.")
        XCTAssertEqual(MailRecipientParser.problem(" , ; ", required: true), "Add a recipient.")
    }

    func testSuggestionsAreLocalOnly() {
        let suggestion = MailRecipientSuggestion(contact: .init(name: "Sam", address: "sam@example.com"), source: .localMail)
        XCTAssertEqual(suggestion.id, "sam@example.com")
        XCTAssertEqual(suggestion.source, .localMail)
    }
    func testPendingAddressIsIncludedBeforeReturnOrFocusChange() {
        var editor = MailRecipientEditingState(committed: "first@example.com")
        editor.pending = "second@example.com"
        XCTAssertEqual(editor.header, "first@example.com, second@example.com")
        editor.commit()
        XCTAssertEqual(editor.header, "first@example.com, second@example.com")
        XCTAssertTrue(editor.pending.isEmpty)
    }

    func testSuggestionReplacesPendingQueryAndPreservesExistingRecipient() {
        var editor = MailRecipientEditingState(committed: "first@example.com")
        editor.pending = "sam"
        editor.choose(.init(name: "Sam", address: "sam@example.com"))
        XCTAssertEqual(editor.header, "first@example.com, Sam <sam@example.com>")
    }

    func testIncompletePendingCcIsPreservedForValidation() {
        var editor = MailRecipientEditingState(committed: "")
        editor.pending = "unfinished"
        XCTAssertNotNil(MailRecipientParser.problem(editor.header, required: false))
        editor.commit()
        XCTAssertEqual(editor.header, "unfinished")
    }

}
