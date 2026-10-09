import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailFeatureIntegrationTests: XCTestCase {
    func testToolsReturnToTheKeptDraftWithoutDiscardingIt() {
        let model = MailSnapshots.workspace(drafts: true)
        let id = model.draft?.id
        let page = MailPage(mail: model, accountCenter: NativeMailCenter(backend: .jevcast, accounts: [], defaults: nil))
        page.tool = .rules
        XCTAssertTrue(page.isTyping)
        XCTAssertFalse(page.composing)
        XCTAssertTrue(page.back())
        XCTAssertTrue(page.composing)
        XCTAssertEqual(model.draft?.id, id)
    }

    func testPersistedScheduleBlocksDuplicateManualSend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let features = MailFeatureCenter(directory: root, defaults: nil, accounts: [])
        let model = MailSnapshots.workspace(drafts: true)
        let draft = try XCTUnwrap(model.draft)
        _ = try features.schedules.schedule(draft, account: .init(accountID: "demo", address: "alex@example.com"), at: Date().addingTimeInterval(3600))
        let restarted = MailFeatureCenter(directory: root, defaults: nil, accounts: [])
        restarted.start(model: model)
        defer { restarted.stop() }
        XCTAssertEqual(model.send(), "This draft is held in Scheduled. Review or cancel it there before sending.")
        XCTAssertEqual(model.draft?.id, draft.id)
        XCTAssertFalse(model.sending)
    }

    func testUncertainScheduleReturnedToDraftsStillRequiresReview() throws {
        let model = MailSnapshots.workspace()
        let draft = MailModel.Draft(backend: MailBackend.jevcast.rawValue, fromAccountID: "demo", fromAddress: "alex@example.com", to: "sam@example.com", subject: "Review", body: "Retained")
        let item = MailScheduleEntry(id: UUID(), account: .init(accountID: "demo", address: "alex@example.com"), draft: draft,
            createdAt: Date(), scheduledAt: Date(), state: .needsReview, note: nil, lastAttemptAt: Date())
        model.restoreScheduled(item)
        XCTAssertTrue(try XCTUnwrap(model.draft).uncertainSend)
        XCTAssertEqual(model.deliveries.first?.state, .uncertain)
        XCTAssertNotNil(model.send())
        XCTAssertFalse(model.sending)
    }

    func testSnoozeFiltersOnlyTheSameAccountAndReturnsOutsideInbox() {
        let model = MailSnapshots.workspace()
        let first = model.messages[0]
        var other = MailSummary(rowID: 99, mailbox: 20, subject: first.subject, senderName: first.senderName,
            senderAddress: first.senderAddress, snippet: "", date: first.date, read: false, flagged: false,
            conversation: 99, messageKey: first.messageKey)
        other.labels = []
        model.snoozedMessageKeys = [model.snoozeKey(for: first)]
        model.install([first, other])
        XCTAssertEqual(model.messages.map(\.rowID), [99])
        model.place = .allMail
        model.install([first, other])
        XCTAssertEqual(Set(model.messages.map(\.rowID)), [first.rowID, 99])
    }

    func testExportStripsOnlyEMLXFramingAndRejectsTruncation() throws {
        let raw = Data("Subject: Café\r\n\r\nLine one\r\nFrom body line\r\n".utf8)
        var framed = Data("\(raw.count)\n".utf8)
        framed.append(raw); framed.append(Data("<plist>private flags</plist>".utf8))
        XCTAssertEqual(try MailMessageExport.rawEMLX(framed), raw)
        XCTAssertThrowsError(try MailMessageExport.rawEMLX(Data("200\nshort".utf8)))
        XCTAssertThrowsError(try MailMessageExport.rawEMLX(Data("-1\nshort".utf8)))
    }
}
