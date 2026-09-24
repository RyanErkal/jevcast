import AppKit
import LauncherCore

extension Diagnostics {
    /// `--diagnose-source 'scheduled tasks'`: prints the rows a source query lists, with each row's verbs.
    /// Runs nothing. Output stays in the terminal.
    static func source(_ text: String) {
        guard let query = SourceQuery.parse(text) else { print("Not a source query: \(text)"); exit(1) }
        let catalogue = AppCatalogue()
        catalogue.refresh(extra: [])
        let model = LauncherModel(preferences: Preferences(), catalogue: catalogue)
        Task { @MainActor in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                guard let source = model.source(query.kind) else { print("No source for \(query.kind.rawValue) yet."); exit(1) }
                let rows = try await source.load(query.filter)
                print("\(source.section): \(rows.count) rows in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms")
                for row in rows {
                    print("• \(row.title)\n  \(row.detail)")
                    if case .thing(let thing) = row.action { print("  verbs: " + thing.verbs.map(\.title).joined(separator: ", ")) }
                }
            } catch {
                print("Problem: \(error.localizedDescription)")
            }
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.run()
    }
}

extension Diagnostics {
    /// `--diagnose-mail`: checks that Jevcast can read Apple Mail. Prints counts and column names only,
    /// never subjects, names, or addresses.
    static func mail() {
        let status = MailStore.status()
        if case .ready(let root) = status { print("Mail status: ready (\((root as NSString).lastPathComponent))") } else { print("Mail status: \(status)") }
        guard case .ready(let root) = status else { exit(status == .noMail ? 1 : 2) }
        do {
            let db = try MailStore.open(root)
            print("messages columns: " + db.columns("messages").sorted().joined(separator: ", "))
            let boxes = try MailStore.mailboxes(root: root)
            let roles = Dictionary(grouping: boxes, by: { "\($0.role)" }).mapValues(\.count)
            print("Mailboxes: \(boxes.count) \(roles.sorted { $0.key < $1.key })")
            let inbox = boxes.filter { $0.role == .inbox }
            let start = CFAbsoluteTimeGetCurrent()
            let recent = try MailStore.messages(root: root, .init(mailboxes: inbox.map(\.rowID), limit: 50))
            print("Inbox list: \(recent.count) rows in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms, unread \(recent.filter { !$0.read }.count)")
            var found = 0
            for message in recent.prefix(20) {
                if let box = boxes.first(where: { $0.rowID == message.mailbox }), MailStore.messageFile(root: root, mailbox: box, rowID: message.rowID) != nil { found += 1 }
            }
            print("Message files found for \(found) of \(min(20, recent.count)) recent messages")
        } catch {
            print("Problem: \(error.localizedDescription)")
            exit(3)
        }
        exit(0)
    }
}

extension Diagnostics {
    /// `--diagnose-mail-actions <file>`: checks, without changing anything, that Apple Mail can find
    /// the newest inbox messages the way the Delete and Archive actions do. Writes account and
    /// message IDs and any error text to `file`. Never subjects, names, or addresses.
    static func mailActions(to file: String) {
        var lines: [String] = []
        func finish() -> Never {
            try? lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard case .ready(let root) = MailStore.status() else { lines.append("Mail status: \(MailStore.status())"); finish() }
        Task { @MainActor in
            do {
                let boxes = try MailStore.mailboxes(root: root)
                let inboxes = boxes.filter { $0.role == .inbox }
                lines.append("Inbox mailboxes: " + inboxes.map { "\($0.rowID) \($0.url.components(separatedBy: "://").first ?? "")://<account>/\($0.path)" }.joined(separator: ", "))
                let recent = try MailStore.messages(root: root, .init(mailboxes: inboxes.map(\.rowID), limit: 3))
                let listAccounts = """
                on run argv
                  tell application id "com.apple.mail"
                    set out to ""
                    repeat with a in accounts
                      set out to out & (id of a) & " | " & (count of mailboxes of a) & linefeed
                    end repeat
                    return out
                  end tell
                end run
                """
                try await MailActions.ensureRunning()
                let accounts = (try? await AppleScript.run(listAccounts, app: MailActions.bundleID, name: "Mail", timeout: 30)) ?? "(could not list accounts)"
                lines.append("Mail account ids | mailboxes:\n" + accounts)
                lines.append("Index account ids: " + Set(inboxes.map(\.accountID)).sorted().joined(separator: ", "))
                let probe = """
                on run argv
                  with timeout of 20 seconds
                    tell application id "com.apple.mail"
                \(MailScripts.findMessage)
                      return "found, id " & (id of m)
                    end tell
                  end timeout
                end run
                """
                for message in recent {
                    guard let box = boxes.first(where: { $0.rowID == message.mailbox }) else { continue }
                    do {
                        let result = try await AppleScript.run(probe, [box.accountID, box.path, String(message.rowID)], app: MailActions.bundleID, name: "Mail", timeout: 30)
                        lines.append("Row \(message.rowID) in \(box.path): \(result.trimmingCharacters(in: .whitespacesAndNewlines))")
                    } catch {
                        lines.append("Row \(message.rowID) in \(box.path): ERROR \(error.localizedDescription)")
                    }
                }
            } catch { lines.append("Problem: \(error.localizedDescription)") }
            finish()
        }
        RunLoop.main.run()
    }
}
