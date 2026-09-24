import Foundation

/// A query that asks for one kind of thing on the Mac: "scheduled tasks", "tabs slack",
/// "reminders", "contact sam". The rest of the query filters the list. The launcher adds
/// these rows to a normal search, so "calendar" still lists the Calendar app.
public struct SourceQuery: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case scheduled, calendar, reminders, contacts, tabs, history, mail, taskRuns, help, cleanup
    }
    public let kind: Kind
    /// Words after the keyword, such as "slack" in "tabs slack". Empty lists everything.
    public let filter: String
    /// True when the words clearly ask for the list, such as "show mail" rather than "mail",
    /// so its main row may rank above an app with the same name.
    public let explicit: Bool
    public init(kind: Kind, filter: String, explicit: Bool = false) { self.kind = kind; self.filter = filter; self.explicit = explicit }
    public static func == (lhs: SourceQuery, rhs: SourceQuery) -> Bool { lhs.kind == rhs.kind && lhs.filter == rhs.filter }

    /// Longest keywords first, so "scheduled tasks" wins over "tasks".
    private static let keywords: [(phrase: String, kind: Kind, takesFilter: Bool)] = [
        ("clean up", .cleanup, false), ("cleanup", .cleanup, false), ("cool down", .cleanup, false), ("cooldown", .cleanup, false),
        ("free memory", .cleanup, false), ("free up memory", .cleanup, false), ("stop background stuff", .cleanup, false),
        ("task results", .taskRuns, true), ("luna results", .taskRuns, true), ("task log", .taskRuns, true), ("task runs", .taskRuns, true),
        ("what can you do", .help, false), ("what can jevcast do", .help, false), ("help", .help, true), ("jevcast", .help, true),
        ("my automations", .scheduled, true), ("automations", .scheduled, true), ("automation", .scheduled, true),
        ("luna tasks", .scheduled, true), ("scheduled tasks", .scheduled, true), ("schedule", .scheduled, true), ("scheduled jobs", .scheduled, true), ("background tasks", .scheduled, true),
        ("background items", .scheduled, true), ("launch agents", .scheduled, true), ("launch daemons", .scheduled, true),
        ("login items", .scheduled, true), ("cron jobs", .scheduled, true), ("what runs at login", .scheduled, false),
        ("what runs on my mac", .scheduled, false), ("scheduled", .scheduled, true), ("schedules", .scheduled, true),
        ("launchd", .scheduled, true), ("crontab", .scheduled, true), ("crons", .scheduled, true), ("cron", .scheduled, true),
        ("my day", .calendar, false), ("whats next", .calendar, false), ("what's next", .calendar, false),
        ("calendar", .calendar, true), ("agenda", .calendar, true), ("events", .calendar, true), ("meetings", .calendar, true),
        ("reminders", .reminders, true), ("to do", .reminders, true), ("todos", .reminders, true), ("todo", .reminders, true),
        ("tasks", .reminders, true),
        ("contacts", .contacts, true), ("contact", .contacts, true),
        ("browser tabs", .tabs, true), ("open tabs", .tabs, true), ("tabs", .tabs, true), ("tab", .tabs, true),
        ("browser history", .history, true), ("web history", .history, true),
        ("inbox", .mail, true), ("mail", .mail, true), ("email", .mail, false), ("emails", .mail, false)
    ]
    /// Words that may come before a keyword: "show me our scheduled tasks", "list my reminders".
    private static let leadIns: Set<String> = ["show", "me", "list", "open", "our", "my", "all", "the", "see", "view", "check", "whats", "what's", "get"]

    public static func parse(_ text: String) -> SourceQuery? {
        // Dictation adds capitals and full stops: "Show mail." reads as "show mail".
        var words = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?, ")).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let full = words.joined(separator: " ")
        // Whole-phrase keywords that read as a question keep their lead-in words.
        for entry in keywords where !entry.takesFilter && full == entry.phrase { return SourceQuery(kind: entry.kind, filter: "", explicit: true) }
        let hadLeadIn = words.count > 1 && leadIns.contains(words[0])
        while words.count > 1, leadIns.contains(words[0]) { words.removeFirst() }
        let phrase = words.joined(separator: " ")
        for entry in keywords {
            if phrase == entry.phrase { return SourceQuery(kind: entry.kind, filter: "", explicit: hadLeadIn || entry.phrase.contains(" ")) }
            guard entry.takesFilter, phrase.hasPrefix(entry.phrase + " ") else { continue }
            return SourceQuery(kind: entry.kind, filter: String(phrase.dropFirst(entry.phrase.count + 1)).trimmingCharacters(in: .whitespaces), explicit: true)
        }
        // "history slack" searches browser history. Bare "history" stays the calculator history.
        if words.count >= 2, words[0] == "history" {
            return SourceQuery(kind: .history, filter: words.dropFirst().joined(separator: " "))
        }
        return nil
    }
}
