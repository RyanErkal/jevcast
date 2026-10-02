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
                for row in query.kind == .mail ? [] : rows {
                    print("• \(row.title)\n  \(row.detail)")
                    if case .thing(let thing) = row.action { print("  verbs: " + thing.verbs.map(\.title).joined(separator: ", ")) }
                }
            } catch {
                print(query.kind == .mail ? "Mail diagnostic failed." : "Problem: \(error.localizedDescription)")
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
        print("Mail source: " + MailBackend.current.title + (NativeMailCenter.isActive ? " (\(NativeMailCenter.loadAccounts().count) accounts)" : ""))
        if case .ready(let root) = status { print("Mail status: ready (\((root as NSString).lastPathComponent))") } else { print("Mail status: \(status)") }
        guard case .ready(let root) = status else { exit(status == .noMail ? 1 : 2) }
        do {
            let db = try MailStore.open(root)
            print("messages columns: " + db.columns("messages").sorted().joined(separator: ", "))
            // Names only, to see which search-friendly tables and indexes this Mail version has.
            let names = { (type: String) in try db.rows("SELECT name FROM sqlite_master WHERE type = ? ORDER BY name", [.text(type)]).compactMap { $0.first?.text } }
            print("Tables: " + (try names("table")).joined(separator: ", "))
            print("messages indexes: " + (try db.rows("SELECT name FROM pragma_index_list('messages') ORDER BY name").compactMap { $0.first?.text }).joined(separator: ", "))
            // Gmail keeps membership (Inbox, Sent, labels) in `labels`; names only.
            if let labels = MailStore.labelTable(db) {
                let indexes = (try db.rows("SELECT name FROM pragma_index_list('labels') ORDER BY name").compactMap { $0.first?.text })
                let mailboxIndexed = try indexes.contains { name in
                    try db.rows("SELECT name FROM pragma_index_info(?) ORDER BY seqno LIMIT 1", [.text(name)]).first?.first?.text == labels.mailbox
                }
                let columns: String = db.columns("labels").sorted().joined(separator: ", ")
                let indexList: String = indexes.isEmpty ? "none" : indexes.joined(separator: ", ")
                let indexed: String = mailboxIndexed ? "yes" : "no (label lists scan the labels table)"
                print("labels table: yes, columns: \(columns); indexes: \(indexList); mailbox column indexed: \(indexed)")
            } else {
                print("labels table: no")
            }
            print("Mailbox and date index: " + (MailStore.hasMailboxDateIndex(root: root) ? "yes" : "no (each mailbox is sorted in full)"))
            let boxes = try MailStore.mailboxes(root: root)
            print("Mailboxes: \(boxes.count)")
            let byRole = Dictionary(grouping: boxes, by: { "\($0.role)" })
            for (role, group) in byRole.sorted(by: { $0.key < $1.key }) {
                print("  \(role): \(group.count) mailboxes, \(try MailStore.count(root: root, mailboxes: group.map(\.rowID))) messages (label members included)")
            }
            let inbox = boxes.filter { $0.role == .inbox }
            // Accounts are numbered in index order; no addresses or account IDs.
            var accounts: [String] = []
            for box in inbox where !accounts.contains(box.accountID) { accounts.append(box.accountID) }
            for (number, account) in accounts.enumerated() {
                let ids = inbox.filter { $0.accountID == account }.map(\.rowID)
                let unread = inbox.filter { $0.accountID == account }.map(\.unread).reduce(0, +)
                print("  inbox of account \(number + 1): \(try MailStore.count(root: root, mailboxes: ids)) messages, \(unread) unread")
            }
            let allMail = boxes.filter(\.inAllMail).map(\.rowID)
            if !NativeMailCenter.isActive {
                print("Apple Mail running: " + (AppleScript.isRunning(MailActions.bundleID) ? "yes" : "no (new mail is not arriving)"))
            }
            func timed<T>(_ body: () throws -> T) rethrows -> (T, Int) {
                let start = CFAbsoluteTimeGetCurrent()
                let value = try body()
                return (value, Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded()))
            }
            let (first, firstMs) = try timed { try MailStore.page(root: root, MailModel.query(.inbox, "", boxes)) }
            let (next, nextMs) = try timed { try MailStore.page(root: root, MailModel.query(.inbox, "", boxes).after(nil, before: first.last)) }
            let inboxTotal = try MailStore.count(root: root, mailboxes: inbox.map(\.rowID))
            print("Messages in inboxes: \(inboxTotal); first page shows \(first.messages.count), next page \(next.messages.count), more pages: \(next.hasMore ? "yes" : "no")")
            let (allCount, allMs) = try timed { try MailStore.count(root: root, mailboxes: allMail, distinct: true) }
            print("All Mail: \(allCount) emails in \(allMail.count) mailboxes (counted in \(allMs) ms)")
            let (_, warmMs) = try timed { try MailStore.page(root: root, MailModel.query(.inbox, "", boxes)) }
            let search = MailModel.query(.allMail, "the", boxes)
            let (_, searchMs) = try timed { try MailStore.page(root: root, search) }
            let (body, bodyMs) = try timed { try MailStore.searchBodies(root: root, search) }
            // A text in no message reads every summary in All Mail: the cost of a full body search.
            let (full, fullMs) = try timed { try MailStore.searchBodies(root: root, MailModel.query(.allMail, "zqxjv-none-7731", boxes), budget: 30) }
            print("Timings: first page \(firstMs) ms (again \(warmMs) ms), next page \(nextMs) ms")
            print("Search timings: subject and sender phase \(searchMs) ms; body phase \(bodyMs) ms (\(body.messages.count) matches, \(body.done ? "all read" : "more to read")); full body read \(fullMs) ms (\(full.done ? "complete" : "stopped at 30 s"))")
            let recent = first.messages
            print("Unread in first page: \(recent.filter { !$0.read }.count)")
            var found = 0
            for message in recent.prefix(20) {
                if let box = boxes.first(where: { $0.rowID == message.mailbox }), MailStore.messageFile(root: root, mailbox: box, rowID: message.rowID) != nil { found += 1 }
            }
            print("Message files found for \(found) of \(min(20, recent.count)) recent messages")
        } catch {
            print("Mail diagnostic failed.")
            exit(3)
        }
        exit(0)
    }
}

extension Diagnostics {
    /// `--diagnose-mail-actions <file>`: checks, without changing anything, that Apple Mail can find
    /// the newest inbox messages the way the Delete and Archive actions do. Writes
    /// counts to `file`. Never subjects, names, addresses, or raw errors.
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
                lines.append("Inbox mailboxes: \(inboxes.count)")
                let recent = try MailStore.messages(root: root, .init(mailboxes: inboxes.map(\.rowID), limit: 3))
                let listAccounts = """
                on run argv
                  tell application id "com.apple.mail"
                    set out to ""
                    repeat with a in accounts
                      set out to out & (count of mailboxes of a) & linefeed
                    end repeat
                    return out
                  end tell
                end run
                """
                try await MailActions.ensureRunning()
                let accounts = (try? await AppleScript.run(listAccounts, app: MailActions.bundleID, name: "Mail", timeout: 30)) ?? "(could not list accounts)"
                lines.append("Mailbox counts by account:\n" + accounts)
                lines.append("Index accounts: \(Set(inboxes.map(\.accountID)).count)")
                let probe = """
                on run argv
                  with timeout of 20 seconds
                    tell application id "com.apple.mail"
                \(MailScripts.findMessage)
                      return "found"
                    end tell
                  end timeout
                end run
                """
                for message in recent {
                    guard let box = boxes.first(where: { $0.rowID == message.mailbox }) else { continue }
                    do {
                        _ = try await AppleScript.run(probe, MailActions.target(message, box), app: MailActions.bundleID, name: "Mail", timeout: 30)
                        lines.append("Messages found: 1")
                    } catch {
                        lines.append("Messages not found: 1")
                    }
                }
            } catch { lines.append("Mail action diagnostic failed.") }
            finish()
        }
        RunLoop.main.run()
    }
}

extension Diagnostics {
    /// `--cleanup`: prints the cleanup checklist. `--cleanup --apply` then stops the checked items,
    /// exactly as Return on the Clean Up row does.
    static func cleanup(apply: Bool) {
        Task { @MainActor in
            let items = await Cleanup.scan(ignored: Set(Preferences().cleanupIgnored))
            if items.isEmpty { print("Nothing to clean up."); exit(0) }
            for item in items {
                print("\(item.finding.checked ? "[x]" : "[ ]") \(item.finding.group.title): \(item.finding.title) · \(Cleanup.size(item.finding.memoryMB)) · \(item.finding.detail)")
            }
            let checked = items.filter(\.finding.checked)
            print("Checked: \(checked.count), using up to \(Cleanup.size(checked.map(\.finding.memoryMB).reduce(0, +)))")
            if apply {
                let before = Cleanup.availableMB()
                for item in checked { print("→ " + (await Cleanup.stop(item))) }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                print("Memory now free: \(Cleanup.size(Cleanup.availableMB() - before)) more than before")
            }
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.run()
    }
}
