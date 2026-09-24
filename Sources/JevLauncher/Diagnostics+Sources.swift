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
