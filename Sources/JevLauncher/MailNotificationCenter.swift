import Foundation
import SwiftUI
import LauncherCore

/// Delivers mail notices through the existing notch. The root owns the `onAction` bridge and can
/// open a message in the launcher page; this type never creates a window or calls UserNotifications.
@MainActor
final class MailNotificationCenter: ObservableObject {
    static let alertPrefix = "mail-notification:"
    static let openActionPrefix = "mail-open:"

    @Published private(set) var settings: MailNotificationSettings
    @Published private(set) var settingsError: String?
    @Published private(set) var lastSuppression: MailNotificationSuppression?
    @Published private(set) var lastNotice: MailNotificationNotice?
    @Published private(set) var persistenceError: String?

    let ledger: MailNotificationLedger
    private let defaults: UserDefaults?
    private let showOnNotch: @MainActor (NotchAlert) -> Void
    private let openMessage: (String) -> Void
    private var messagesByID: [String: MailNotificationMessage] = [:]

    init(ledgerURL: URL = MailNotificationLedger.defaultURL,
         defaults: UserDefaults? = .standard,
         showOnNotch: @escaping @MainActor (NotchAlert) -> Void = { NotchAlertController.shared.show($0) },
         openMessage: @escaping (String) -> Void = { _ in }) {
        self.ledger = MailNotificationLedger(url: ledgerURL)
        self.defaults = defaults
        self.showOnNotch = showOnNotch
        self.openMessage = openMessage
        if let data = defaults?.data(forKey: "mailNotificationSettings") {
            do {
                let decoded = try JSONDecoder().decode(MailNotificationSettings.self, from: data)
                guard decoded.validates() else { throw MailNotificationStoreError.unreadable("Saved notification settings are invalid.") }
                settings = decoded
                settingsError = nil
            } catch { settings = MailNotificationSettings(); settingsError = error.localizedDescription }
        } else {
            settings = MailNotificationSettings(); settingsError = nil
        }
        persistenceError = ledger.loadError
    }

    static var defaultLedgerURL: URL { MailNotificationLedger.defaultURL }

    func setAccount(_ accountID: String, enabled: Bool) {
        var next = settings
        if enabled { next.enabledAccounts.insert(accountID) } else { next.enabledAccounts.remove(accountID) }
        saveSettings(next)
    }

    func setPrivatePreviews(_ privatePreviews: Bool) {
        var next = settings; next.privatePreviews = privatePreviews; saveSettings(next)
    }

    func setQuietHours(startMinute: Int?, endMinute: Int?) {
        var next = settings; next.quietStartMinute = startMinute; next.quietEndMinute = endMinute
        guard next.validates() else { return }
        saveSettings(next)
    }

    /// Root calls this after a sync batch. `initialLoad` must be true for the first or history batch
    /// of an account so old mail becomes a durable baseline instead of a notification flood.
    func observe(_ messages: [MailNotificationMessage], initialLoad: Bool = false,
                 now: Date = Date(), calendar: Calendar = .current) {
        guard !messages.isEmpty else { return }
        if initialLoad {
            var persisted = true
            Dictionary(grouping: messages, by: \.accountID).forEach { account, batch in
                persisted = ledger.establishBaseline(accountID: account, messages: batch, at: now) && persisted
            }
            if persisted { lastSuppression = .initialHistory }
            else { lastSuppression = .persistenceFailure; persistenceError = ledger.persistenceError ?? ledger.loadError }
            return
        }
        for message in messages {
            messagesByID[message.id] = message
            switch ledger.decide(message, settings: settings, now: now, calendar: calendar) {
            case .deliver(let notice):
                lastNotice = notice
                var alert = NotchAlert(id: Self.alertPrefix + notice.id, kind: .info, symbol: "envelope.badge",
                                       title: notice.title, message: notice.message,
                                       actions: [.init("Open Mail", id: Self.openActionPrefix + notice.id, primary: true),
                                                 .init("Dismiss", id: NotchAlert.dismissAction)])
                alert.minimized = true
                showOnNotch(alert)
            case .suppress(let reason):
                lastSuppression = reason
                if reason == .persistenceFailure { persistenceError = ledger.persistenceError ?? ledger.loadError }
            }
        }
    }

    /// Returns true when the action belongs to this center. Root may chain this before automation
    /// action handling without allowing a late notch button to target another card.
    @discardableResult func handle(alert: NotchAlert, action: String) -> Bool {
        guard alert.id.hasPrefix(Self.alertPrefix) else { return false }
        if action == NotchAlert.dismissAction { return true }
        guard action.hasPrefix(Self.openActionPrefix) else { return false }
        let id = String(action.dropFirst(Self.openActionPrefix.count))
        guard messagesByID[id] != nil else { return false }
        openMessage(id)
        return true
    }

    private func saveSettings(_ next: MailNotificationSettings) {
        guard next.validates() else { return }
        guard settingsError == nil else { persistenceError = settingsError; return }
        settings = next
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: "mailNotificationSettings") }
    }
}
