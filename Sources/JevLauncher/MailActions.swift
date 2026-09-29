import AppKit
import LauncherCore

/// Changes to mail go through Apple Mail, so its accounts, rules, and sync stay in charge.
/// Mail starts hidden when it is not running. Values reach the fixed scripts only as arguments.
/// With Jevcast accounts as the mail source, each change goes to `NativeMailEngine` instead, and
/// Apple Mail is never started.
enum MailActions {
    static let bundleID = "com.apple.mail"
    /// Set when you open a message in Mail itself, so Jevcast does not quit Mail after.
    static var openedByUser = false

    /// The engine for Jevcast accounts, or nil when Apple Mail is the mail source.
    private static func native() throws -> NativeMailEngine? {
        guard NativeMailCenter.isActive else { return nil }
        guard let engine = NativeMailCenter.activeEngine else { throw LauncherError("Add a mail account in Settings › Mail first.") }
        return engine
    }

    /// The launch in progress. Callers that arrive meanwhile wait for it instead of opening Mail
    /// again: a second open reaches a Mail that is still starting, and Mail answers it by showing
    /// its window.
    @MainActor private static var launch: Task<Void, Error>?

    /// Starts Mail hidden, without taking focus, and waits until it answers.
    static func ensureRunning() async throws {
        if NativeMailCenter.isActive { return }
        try await launchOnce()
    }

    @MainActor private static func launchOnce() async throws {
        if let launch { return try await launch.value }
        if AppleScript.isRunning(bundleID) { return }
        let task = Task { @MainActor in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw LauncherError("Apple Mail is not installed.")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false; config.hides = true; config.addsToRecentItems = false
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            for _ in 0..<40 where !AppleScript.isRunning(bundleID) { try await Task.sleep(nanoseconds: 100_000_000) }
            // Mail answers scripts a moment after it launches.
            try await Task.sleep(nanoseconds: 800_000_000)
            // Mail can restore its last window while it starts. The Mail that Jevcast started stays out of sight.
            _ = app.hide()
        }
        launch = task
        defer { launch = nil }
        try await task.value
    }

    static func run(_ script: String, _ arguments: [String]) async throws {
        try await ensureRunning()
        _ = try await AppleScript.run(script, arguments, app: bundleID, name: "Mail", timeout: 30)
    }

    /// Runs a script that sends mail. When Mail may have sent the message, the error is `MailMaybeSentError`.
    private static func runSending(_ script: String, _ arguments: [String]) async throws {
        try await ensureRunning()
        // Nothing has reached Mail yet, so a cancel here means nothing was sent.
        try Task.checkCancellation()
        do { _ = try await AppleScript.run(script, arguments, app: bundleID, name: "Mail", timeout: 30) }
        catch { throw sendFailure(error) }
    }

    /// What a failed send script means. 1005 is an error from Mail's `send` itself. A timeout (-1712),
    /// the osascript time limit, or a cancel stops the script at a point Jevcast cannot know. In each
    /// of these cases Mail may have sent the message. Every other error, such as 1002, 1003, or 1004
    /// (an error before `send`), means that Mail did not send it.
    static func sendFailure(_ error: Error) -> Error {
        if error is CancellationError { return MailMaybeSentError() }
        guard let failure = error as? CommandRunner.Failure else { return error }
        if let code = errorNumber(failure.text), code == 1005 || code == -1712 { return MailMaybeSentError() }
        // `CommandRunner` ends a script at its time limit with this text.
        if failure.text.hasSuffix("took too long and was stopped.") { return MailMaybeSentError() }
        return error
    }

    /// The number at the end of an osascript error line, such as 1005 in "0:12: execution error: … (1005)".
    static func errorNumber(_ text: String) -> Int? {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        return Int(text[text.index(after: open)..<text.index(before: text.endIndex)])
    }

    /// The number of messages in Mail's Outbox: 0 when Mail is not running, nil when Mail does not
    /// answer. It never starts Mail.
    static func outboxCount() async -> Int? {
        guard AppleScript.isRunning(bundleID) else { return 0 }
        guard let output = try? await AppleScript.run(MailScripts.outboxCount, app: bundleID, name: "Mail", timeout: 15),
              let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return max(count, 0)
    }

    private static func target(_ message: MailSummary, _ mailbox: MailMailbox) -> [String] {
        [mailbox.accountID, mailbox.path, String(message.rowID)]
    }

    /// Mail can miss a change in its first seconds after it starts, so a failed change is tried once
    /// more, in `fallback` when given: the row's own mailbox, such as Gmail's All Mail for an Inbox row.
    /// Read status belongs to the message, so either mailbox changes it on the server.
    static func setRead(_ read: Bool, _ message: MailSummary, in mailbox: MailMailbox, fallback: MailMailbox? = nil) async throws {
        if let engine = try native() { return try await engine.setRead(message.rowID, read) }
        let value = read ? "true" : "false"
        do { try await run(MailScripts.setRead, target(message, mailbox) + [value]) }
        catch let problem as SourceProblem { throw problem }
        catch {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await run(MailScripts.setRead, target(message, fallback ?? mailbox) + [value])
        }
    }
    /// Asks Mail to send pending changes for these accounts to their servers. Does nothing when Mail is not running.
    static func synchronize(accounts: [String]) async throws {
        guard !accounts.isEmpty, !NativeMailCenter.isActive, AppleScript.isRunning(bundleID) else { return }
        _ = try await AppleScript.run(MailScripts.synchronize, accounts, app: bundleID, name: "Mail", timeout: 30)
    }
    static func setFlagged(_ flagged: Bool, _ message: MailSummary, in mailbox: MailMailbox) async throws {
        if let engine = try native() { return try await engine.setFlagged(message.rowID, flagged) }
        try await run(MailScripts.setFlagged, target(message, mailbox) + [flagged ? "true" : "false"])
    }
    static func delete(_ message: MailSummary, in mailbox: MailMailbox) async throws {
        if let engine = try native() { return try await engine.delete(message.rowID) }
        try await run(MailScripts.delete, target(message, mailbox))
    }
    static func move(_ message: MailSummary, from mailbox: MailMailbox, to destination: MailMailbox) async throws {
        guard destination.accountID == mailbox.accountID else { throw LauncherError("Messages move only within one account.") }
        if let engine = try native() { return try await engine.move(message.rowID, to: destination.rowID) }
        try await run(MailScripts.move, target(message, mailbox) + [destination.path])
    }
    /// Apple Mail gets the text without leading white space, so Mail's copy starts with `checkText`.
    static func reply(_ message: MailSummary, in mailbox: MailMailbox, text: String, all: Bool) async throws {
        if let engine = try native() { return try await engine.reply(to: message.rowID, text: text, all: all) }
        let text = MailScripts.sendingText(text)
        try await runSending(MailScripts.reply, target(message, mailbox) + [text, all ? "true" : "false", MailScripts.checkText(text)])
    }
    static func forward(_ message: MailSummary, in mailbox: MailMailbox, text: String, to recipients: [String]) async throws {
        if let engine = try native() { return try await engine.forward(message.rowID, text: text, to: recipients) }
        let text = MailScripts.sendingText(text)
        try await runSending(MailScripts.forward, target(message, mailbox) + [text, recipients.joined(separator: "\n"), MailScripts.checkText(text)])
    }
    static func send(to: [String], cc: [String], subject: String, body: String) async throws {
        guard !to.isEmpty else { throw LauncherError("Add at least one recipient.") }
        if let engine = try native() { return try await engine.send(to: to, cc: cc, subject: subject, body: body) }
        let body = MailScripts.sendingText(body)
        try await runSending(MailScripts.send, [to.joined(separator: "\n"), cc.joined(separator: "\n"), subject, body, MailScripts.checkText(body)])
    }
    static func checkForNewMail() async throws {
        if let engine = try native() { return await engine.sync(.inboxOnly) }
        try await run(MailScripts.checkForNewMail, [])
    }
    static func openInMail(_ message: MailSummary, in mailbox: MailMailbox) async throws {
        if NativeMailCenter.isActive { throw LauncherError("Messages from Jevcast accounts open here. Apple Mail does not have them.") }
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

/// A send that failed during or after Mail's `send`, or timed out there: Mail may have sent the
/// message. The composer keeps the draft but says to check Sent, so the user does not send twice.
struct MailMaybeSentError: LocalizedError {
    var errorDescription: String? { "Mail may have sent this message. Check Sent before you send it again." }
}
