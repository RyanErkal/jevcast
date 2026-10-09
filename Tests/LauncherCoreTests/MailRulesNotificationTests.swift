import XCTest
@testable import LauncherCore

final class MailRulesNotificationTests: XCTestCase {
    private var url: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("mail-notifications-" + UUID().uuidString + ".json")
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: url) }

    private func message(_ id: String, at date: Date, account: String = "acc") -> MailNotificationMessage {
        MailNotificationMessage(id: id, accountID: account, sender: "sender@example.com", subject: "Quarterly report", receivedAt: date, isRead: false)
    }

    func testNotificationsAreOffUntilAccountIsEnabled() {
        let ledger = MailNotificationLedger(url: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = ledger.decide(message("m", at: now), settings: MailNotificationSettings(), now: now, calendar: calendar)
        XCTAssertEqual(result, .suppress(.disabledAccount))
    }

    func testInitialHistoryIsBaselinedAndNewMailDeliversOnceAfterRestart() {
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = MailNotificationSettings(enabledAccounts: ["acc"], privatePreviews: false)
        let ledger = MailNotificationLedger(url: url)
        ledger.establishBaseline(accountID: "acc", messages: [message("old", at: baseline)], at: baseline)
        XCTAssertEqual(ledger.decide(message("old", at: baseline), settings: settings, now: baseline), .suppress(.duplicate))
        let newMessage = message("new", at: baseline.addingTimeInterval(1))
        guard case .deliver(let notice) = ledger.decide(newMessage, settings: settings, now: newMessage.receivedAt) else {
            return XCTFail("New mail after the baseline should deliver")
        }
        XCTAssertEqual(notice.message, "Quarterly report")
        let restarted = MailNotificationLedger(url: url)
        XCTAssertEqual(restarted.decide(newMessage, settings: settings, now: newMessage.receivedAt), .suppress(.duplicate))
    }

    func testOldHistoryLoadedAfterBaselineDoesNotFloodNotch() {
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = MailNotificationLedger(url: url)
        ledger.establishBaseline(accountID: "acc", messages: [], at: baseline)
        XCTAssertEqual(ledger.decide(message("history", at: baseline.addingTimeInterval(-100)),
                                     settings: MailNotificationSettings(enabledAccounts: ["acc"]), now: baseline), .suppress(.oldHistory))
    }

    func testQuietHoursAndPrivatePreviews() {
        let startOfDay = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = MailNotificationSettings(enabledAccounts: ["acc"], privatePreviews: true, quietStartMinute: 22 * 60, quietEndMinute: 7 * 60)
        let ledger = MailNotificationLedger(url: url)
        ledger.establishBaseline(accountID: "acc", messages: [], at: startOfDay.addingTimeInterval(-10))
        let quiet = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: startOfDay)!
        XCTAssertEqual(ledger.decide(message("quiet", at: quiet), settings: settings, now: quiet, calendar: calendar), .suppress(.quietHours))
        let daytime = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: startOfDay)!
        let dayLedger = MailNotificationLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent("day-" + UUID().uuidString))
        dayLedger.establishBaseline(accountID: "acc", messages: [], at: daytime.addingTimeInterval(-10))
        guard case .deliver(let notice) = dayLedger.decide(message("day", at: daytime), settings: settings, now: daytime, calendar: calendar) else {
            return XCTFail("Daytime mail should deliver")
        }
        XCTAssertEqual(notice.title, "New mail")
        XCTAssertEqual(notice.message, "A new message arrived")
    }

    func testCorruptLedgerSuppressesDeliveryAndPreservesBytes() throws {
        let original = Data("broken".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let ledger = MailNotificationLedger(url: url)
        XCTAssertNotNil(ledger.loadError)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = ledger.decide(message("new", at: now), settings: MailNotificationSettings(enabledAccounts: ["acc"]), now: now)
        XCTAssertEqual(result, .suppress(.persistenceFailure))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testNonOwnerOnlyLedgerSuppressesDeliveryAndPreservesBytes() throws {
        let original = Data("{}".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let ledger = MailNotificationLedger(url: url)
        XCTAssertNotNil(ledger.loadError)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ledger.decide(message("new", at: now), settings: MailNotificationSettings(enabledAccounts: ["acc"]), now: now), .suppress(.persistenceFailure))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSymlinkedLedgerSuppressesDelivery() throws {
        let target = url.deletingLastPathComponent().appendingPathComponent("notification-outside.json")
        let original = Data("{}".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let ledger = MailNotificationLedger(url: url)
        XCTAssertNotNil(ledger.loadError)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ledger.decide(message("new", at: now), settings: MailNotificationSettings(enabledAccounts: ["acc"]), now: now), .suppress(.persistenceFailure))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
