import Foundation

/// The kinds of request Jev tells apart in its first step. A small, clear list makes the first
/// choice easy; the second step then chooses among every candidate of that one kind.
public enum JevKind: String, CaseIterable, Sendable {
    case openApp, settingsPane, window, files, command, ports, automation, menu, web
    case clipboard, schedule, organizer, mail, browser, people, context, luna

    public var title: String {
        switch self {
        case .openApp: return "Open an application"
        case .settingsPane: return "Open a System Settings pane"
        case .window: return "Move, resize, or arrange a window"
        case .files: return "Find a file or folder"
        case .command: return "Run a system command"
        case .ports: return "A local server or port"
        case .automation: return "Run a Shortcut, workflow, or snippet"
        case .menu: return "Choose a menu item in the front app"
        case .web: return "Search a website"
        case .clipboard: return "Clipboard history"
        case .schedule: return "Timers and scheduled tasks"
        case .organizer: return "Calendar events and reminders"
        case .mail: return "Email"
        case .browser: return "Browser tabs"
        case .people: return "Find a person in Contacts"
        case .context: return "Act on the page, files, or text in front"
        case .luna: return "Answer a question or write text"
        }
    }

    public var detail: String {
        switch self {
        case .openApp: return "The request names an app to open or switch to, such as \"open slack\" or \"launch the music app\""
        case .settingsPane: return "The request is about a macOS setting such as Wi-Fi, Bluetooth, display, or sound settings"
        case .window: return "The request moves, resizes, snaps, tiles, or maximises a window, such as \"make this bigger\" or \"put it on the left\""
        case .files: return "The request looks for a document, download, image, folder, or recent file"
        case .command: return "The request changes the Mac: dark mode, keep awake, empty trash, lock screen, IP address, or the user's own commands"
        case .ports: return "The request is about a dev server, localhost, or a process listening on a port"
        case .automation: return "The request names one of the user's Shortcuts, workflows, or text snippets"
        case .menu: return "The request asks the app in front to do something from its menus, such as export, new tab, or print"
        case .web: return "The request searches a site such as GitHub, YouTube, Maps, or Wikipedia"
        case .clipboard: return "The request asks for something the user copied earlier"
        case .schedule: return "The request is about timers, background jobs, launch agents, cron, or what runs at login"
        case .organizer: return "The request is about meetings, events, the day's agenda, reminders, or to-dos"
        case .mail: return "The request is about email, the inbox, or unread messages"
        case .browser: return "The request is about open browser tabs"
        case .people: return "The request names a person to email, call, or message"
        case .context: return "The request acts on \"this\": the open page, the selected files, or the selected text"
        case .luna: return "The request is a question to answer or text to write, not an action on the Mac"
        }
    }

    /// The kind of a candidate ID. `isSettingsPane` tells an app from a System Settings pane.
    public static func of(_ id: String, isSettingsPane: Bool = false) -> JevKind? {
        if id.hasPrefix("app:") { return isSettingsPane ? .settingsPane : .openApp }
        if id.hasPrefix("window:") || id.hasPrefix("open:") { return .window }
        if id.hasPrefix("file:") || id == "route:files" || id == "route:recent" { return .files }
        if id.hasPrefix("command:") || id.hasPrefix("custom:") { return .command }
        if id == "ports" { return .ports }
        if id.hasPrefix("workflow:") || id.hasPrefix("shortcut:") || id.hasPrefix("snippet:") { return .automation }
        if id.hasPrefix("menu:") { return .menu }
        if id.hasPrefix("quicklink:") { return .web }
        if id == "route:clip" { return .clipboard }
        if id == "route:timers" || id == "route:scheduled" { return .schedule }
        if id == "route:calendar" || id == "route:reminders" { return .organizer }
        if id == "route:mail" { return .mail }
        if id == "route:tabs" { return .browser }
        if id == "route:contacts" { return .people }
        if id == "luna:ask" || id.hasPrefix("this:luna:") { return .luna }
        if id.hasPrefix("this:") { return .context }
        return nil
    }
}

/// How the layered answer is decided from the two first-step replies.
public enum JevLayerPlan: Equatable, Sendable {
    /// The single-list pick agrees with the kind, or there is no kind to check against.
    case accept(String)
    /// Ask again among every candidate of this kind.
    case narrow(JevKind)
    case noMatch

    /// `pick` is the single-list answer and `kind` the first-step kind; `pickKind` is the pick's kind.
    public static func decide(pick: String?, pickKind: JevKind?, kind: JevKind?) -> JevLayerPlan {
        switch (pick, kind) {
        case let (pick?, kind?): return pickKind == kind ? .accept(pick) : .narrow(kind)
        case let (pick?, nil): return .accept(pick)
        // The kind alone never makes a pick: with no answer from the full list, nothing is chosen.
        case (nil, _): return .noMatch
        }
    }
}
