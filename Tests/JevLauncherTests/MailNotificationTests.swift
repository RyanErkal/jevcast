import XCTest
import LauncherCore
@testable import JevLauncher

@MainActor
final class MailNotificationTests: XCTestCase {
    func testCenterUsesNotchClosureAndOpenBridge() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("center-" + UUID().uuidString)
        let defaults = UserDefaults(suiteName: "MailNotificationTests." + UUID().uuidString)!
        var shown: [NotchAlert] = []
        var opened: [String] = []
        let center = MailNotificationCenter(ledgerURL: url, defaults: defaults, showOnNotch: { shown.append($0) }, openMessage: { opened.append($0) })
        center.setAccount("acc", enabled: true)
        let baseline = Date(timeIntervalSince1970: 1_800_000_000)
        let old = MailNotificationMessage(id: "old", accountID: "acc", sender: "old@example.com", subject: "Old", receivedAt: baseline, isRead: false)
        center.observe([old], initialLoad: true, now: baseline)
        let newMessage = MailNotificationMessage(id: "new", accountID: "acc", sender: "sender@example.com", subject: "Hello", receivedAt: baseline.addingTimeInterval(1), isRead: false)
        center.observe([newMessage], now: baseline.addingTimeInterval(1))
        let alert = try! XCTUnwrap(shown.first)
        XCTAssertTrue(alert.id.hasPrefix(MailNotificationCenter.alertPrefix))
        XCTAssertTrue(center.handle(alert: alert, action: MailNotificationCenter.openActionPrefix + "new"))
        XCTAssertEqual(opened, ["new"])
        XCTAssertFalse(center.handle(alert: alert, action: "open"), "A generic action cannot target a mail notice")
        try? FileManager.default.removeItem(at: url)
    }

    func testDefaultSettingsDoNotShowNotice() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("center-off-" + UUID().uuidString)
        let defaults = UserDefaults(suiteName: "MailNotificationTests." + UUID().uuidString)!
        var shown = 0
        let center = MailNotificationCenter(ledgerURL: url, defaults: defaults, showOnNotch: { _ in shown += 1 })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        center.observe([MailNotificationMessage(id: "new", accountID: "acc", sender: "a@b.example", subject: "Hi", receivedAt: now, isRead: false)], now: now)
        XCTAssertEqual(shown, 0)
        XCTAssertEqual(center.lastSuppression, .disabledAccount)
        try? FileManager.default.removeItem(at: url)
    }

    func testCorruptLedgerNeverEmitsNotchAlert() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("center-corrupt-" + UUID().uuidString)
        try! Data("broken".utf8).write(to: url)
        let defaults = UserDefaults(suiteName: "MailNotificationTests." + UUID().uuidString)!
        var shown = 0
        let center = MailNotificationCenter(ledgerURL: url, defaults: defaults, showOnNotch: { _ in shown += 1 })
        center.setAccount("acc", enabled: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        center.observe([MailNotificationMessage(id: "new", accountID: "acc", sender: "a@b.example", subject: "Hi", receivedAt: now, isRead: false)], now: now)
        XCTAssertEqual(shown, 0)
        XCTAssertEqual(center.lastSuppression, .persistenceFailure)
        try? FileManager.default.removeItem(at: url)
    }

    func testCorruptNotificationSettingsStayDisabledAndRefuseOverwrite() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("center-settings-" + UUID().uuidString)
        let defaults = UserDefaults(suiteName: "MailNotificationTests." + UUID().uuidString)!
        let original = Data("broken".utf8)
        defaults.set(original, forKey: "mailNotificationSettings")
        let center = MailNotificationCenter(ledgerURL: url, defaults: defaults, showOnNotch: { _ in })
        XCTAssertNotNil(center.settingsError)
        center.setAccount("acc", enabled: true)
        XCTAssertEqual(defaults.data(forKey: "mailNotificationSettings"), original)
        try? FileManager.default.removeItem(at: url)
    }
}
