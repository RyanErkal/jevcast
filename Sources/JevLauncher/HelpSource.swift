import AppKit

/// "help" or "what can you do": every kind of thing Jevcast finds, with the words that show it.
/// Return types those words into the search field.
@MainActor
final class HelpSource: ThingSource {
    let section = "What Jevcast Can Do"
    static let features: [(title: String, words: String, query: String, symbol: String)] = [
        ("Mail", "show mail · inbox · mail <words>", "show mail", "envelope"),
        ("Scheduled tasks and automations", "scheduled tasks · automations · what runs at login", "automations", "clock.arrow.circlepath"),
        ("Schedule a Luna task", "every weekday at 8am brief me on my meetings", "every weekday at 8am brief me on my meetings", "calendar.badge.clock"),
        ("Task results", "task results", "task results", "doc.text"),
        ("Calendar", "calendar · my day · calendar week", "calendar", "calendar"),
        ("Reminders", "reminders · remind me to … at 5pm", "reminders", "checklist"),
        ("Add an event", "add event lunch with Sam friday 1pm", "add event ", "calendar.badge.plus"),
        ("Contacts", "contact <name>", "contact ", "person.crop.circle"),
        ("Browser tabs", "tabs · tabs <words>", "tabs", "safari"),
        ("Browser history", "history <words>", "history ", "clock"),
        ("This page, file, or selection", "this · copy link", "this", "hand.point.up.left"),
        ("Ask Luna", "ask <question>", "ask ", "sparkles"),
        ("Ports and servers", "ports · port 3000", "ports", "server.rack"),
        ("Clipboard history", "clip", "clip", "doc.on.clipboard"),
        ("Timers", "5m tea · timers", "timers", "timer"),
        ("Files", "find <name> · recent files · kind:pdf in:downloads", "recent files", "doc.text.magnifyingglass")
    ]

    func load(_ filter: String) async throws -> [LauncherResult] {
        Self.features.enumerated().map { index, feature in
            LauncherResult(id: "help:\(index)", title: feature.title, detail: feature.words, symbol: feature.symbol,
                           action: .route(feature.query), score: 3000 - Double(index))
        }
    }
}
