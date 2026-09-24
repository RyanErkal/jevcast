import AppKit
import LauncherCore

/// Changes to mail go through Apple Mail, so its accounts, rules, and sync stay in charge.
/// Mail starts hidden when it is not running. Values reach the fixed scripts only as arguments.
enum MailActions {
    static let bundleID = "com.apple.mail"
    /// Set when you open a message in Mail itself, so Jevcast does not quit Mail after.
    static var openedByUser = false

    /// Starts Mail hidden, without taking focus, and waits until it answers.
    static func ensureRunning() async throws {
        if AppleScript.isRunning(bundleID) { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw LauncherError("Apple Mail is not installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false; config.hides = true; config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<40 where !AppleScript.isRunning(bundleID) { try await Task.sleep(nanoseconds: 100_000_000) }
        // Mail answers scripts a moment after it launches.
        try await Task.sleep(nanoseconds: 800_000_000)
    }

    static func run(_ script: String, _ arguments: [String]) async throws {
        try await ensureRunning()
        _ = try await AppleScript.run(script, arguments, app: bundleID, name: "Mail", timeout: 30)
    }

    private static func target(_ message: MailSummary, _ mailbox: MailMailbox) -> [String] {
        [mailbox.accountID, mailbox.path, String(message.rowID)]
    }

    static func setRead(_ read: Bool, _ message: MailSummary, in mailbox: MailMailbox) async throws {
        try await run(MailScripts.setRead, target(message, mailbox) + [read ? "true" : "false"])
    }
    static func setFlagged(_ flagged: Bool, _ message: MailSummary, in mailbox: MailMailbox) async throws {
        try await run(MailScripts.setFlagged, target(message, mailbox) + [flagged ? "true" : "false"])
    }
    static func delete(_ message: MailSummary, in mailbox: MailMailbox) async throws {
        try await run(MailScripts.delete, target(message, mailbox))
    }
    static func move(_ message: MailSummary, from mailbox: MailMailbox, to destination: MailMailbox) async throws {
        guard destination.accountID == mailbox.accountID else { throw LauncherError("Messages move only within one account.") }
        try await run(MailScripts.move, target(message, mailbox) + [destination.path])
    }
    static func reply(_ message: MailSummary, in mailbox: MailMailbox, text: String, all: Bool) async throws {
        try await run(MailScripts.reply, target(message, mailbox) + [text, all ? "true" : "false"])
    }
    static func forward(_ message: MailSummary, in mailbox: MailMailbox, text: String, to recipients: [String]) async throws {
        try await run(MailScripts.forward, target(message, mailbox) + [text, recipients.joined(separator: "\n")])
    }
    static func send(to: [String], cc: [String], subject: String, body: String) async throws {
        guard !to.isEmpty else { throw LauncherError("Add at least one recipient.") }
        try await run(MailScripts.send, [to.joined(separator: "\n"), cc.joined(separator: "\n"), subject, body])
    }
    static func checkForNewMail() async throws {
        try await run(MailScripts.checkForNewMail, [])
    }
    static func openInMail(_ message: MailSummary, in mailbox: MailMailbox) async throws {
        try await run(MailScripts.open, target(message, mailbox))
    }

    /// "a@b.c, Name <d@e.f>; g@h.i" as addresses. Rejects text that is not an address.
    static func addresses(_ text: String) throws -> [String] {
        let parts = text.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: ",")
        let found = MailAddress.list(parts).map(\.address).filter { !$0.isEmpty }
        for address in found where !(address.contains("@") && !address.contains(" ") && address.split(separator: "@").count == 2) {
            throw LauncherError("“\(address)” is not an email address.")
        }
        return found
    }
}
