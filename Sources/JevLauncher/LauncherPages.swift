import AppKit
import SwiftUI

/// A view that fills the launcher panel in place of the results, such as Mail.
enum ViewID: String, CaseIterable {
    case mail, calendar, tasks, clipboard, cleanup
    var title: String {
        switch self {
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .tasks: return "Tasks"
        case .clipboard: return "Clipboard"
        case .cleanup: return "Clean Up"
        }
    }
    var symbol: String {
        switch self {
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .tasks: return "clock"
        case .clipboard: return "doc.on.clipboard"
        case .cleanup: return "leaf"
        }
    }
}

enum LauncherMode: Equatable {
    case search
    case view(ViewID)
}

/// Keys the launcher passes to a view.
enum PageKey: Equatable { case up, down, left, right, open(shift: Bool), delete }

/// One view in the panel. The search field above it is the view's filter.
@MainActor
protocol LauncherPage: AnyObject {
    var id: ViewID { get }
    /// True while a text box in the view has the keys, such as a mail reply.
    var isTyping: Bool { get }
    /// True when ⌘O opens this view in its own window or app.
    var canPopOut: Bool { get }
    func handle(_ key: PageKey) -> Bool
    func filter(_ text: String)
    /// Leaves a detail level, such as a message back to the list. False at the top level.
    func back() -> Bool
    func popOut()
    func opened()
    /// `handingOff` is true when the view moves to its own window and must keep its data running.
    func closed(handingOff: Bool)
    func content() -> AnyView
}

extension LauncherPage {
    var isTyping: Bool { false }
    var canPopOut: Bool { false }
    func popOut() {}
    func opened() {}
    func closed(handingOff: Bool) {}
}

extension LauncherModel {
    var mode: LauncherMode { page.map { .view($0.id) } ?? .search }

    /// Turns the panel into a view. The typed search is kept and comes back with Escape.
    /// Voice and pending search work stop, so nothing types into the view's filter.
    func showView(_ view: ViewID) {
        guard page?.id != view, let made = makePage?(view) else { return }
        dismissLuna()
        pauseListening()
        revision = UUID(); sourceTask?.cancel()
        viewStack.append((page, query))
        page?.closed(handingOff: false)
        page = made
        query = ""
        made.opened()
        made.filter("")
        refocusSoon()
    }

    /// Goes back one level: to the previous view with its filter, or to search with the text you had typed.
    func closeView(handingOff: Bool = false) {
        guard let current = page else { return }
        current.closed(handingOff: handingOff)
        let previous = viewStack.popLast()
        page = previous?.page ?? nil
        // The rows below still belong to this text, so it comes back as it was.
        query = previous?.query ?? ""
        if let page { page.opened(); page.filter(query) } else if sourceQuery != nil { reloadSource() } else { rebuild() }
        refocusSoon()
    }

    /// Closes every view at once, such as when the panel hides. Views below the top are not reopened.
    func closeAllViews(handingOff: Bool = false) {
        guard let current = page else { return }
        current.closed(handingOff: handingOff)
        query = viewStack.first?.query ?? ""
        viewStack = []
        page = nil
        if sourceQuery != nil && visible { reloadSource() }
    }

    /// The field is made again when the panel changes, so focus waits for the next turn.
    private func refocusSoon() {
        DispatchQueue.main.async { [weak self] in self?.focusSearch?() }
    }

    /// A row that opens a view, above a source's rows: "Open Calendar", "Open Clipboard".
    func viewRow(_ view: ViewID, detail: String, score: Double) -> LauncherResult? {
        guard makePage != nil else { return nil }
        let open = Verb(title: "Open " + view.title, after: .keepOpen) { [weak self] in self?.showView(view); return nil }
        return LauncherResult(id: "view:" + view.rawValue, title: "Open " + view.title, detail: detail, symbol: view.symbol,
                              action: .thing(Thing(verbs: [open], twoLine: false)), score: score)
    }

    /// Text typed in the search field while a view shows.
    func filterView(_ text: String) {
        query = text
        page?.filter(text)
    }

    /// Routes a key while a view shows. Returns true when the view used it.
    func handleViewKey(_ event: NSEvent) -> Bool {
        guard let page else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags == .command, event.keyCode == 31 { // ⌘O
            if page.canPopOut { page.popOut() }
            return true
        }
        if page.isTyping {
            guard event.keyCode == 53 else { return false }
            if !page.back() { closeView() }
            return true
        }
        switch event.keyCode {
        case 53:
            if !page.back() { closeView() }
            return true
        case 125: return page.handle(.down)
        case 126: return page.handle(.up)
        // ← and → move the text cursor while the filter has text.
        case 123: return query.isEmpty && flags.isEmpty ? page.handle(.left) : false
        case 124: return query.isEmpty && flags.isEmpty ? page.handle(.right) : false
        case 36, 76: return page.handle(.open(shift: event.modifierFlags.contains(.shift)))
        case 51:
            // ⌫ edits the filter while it has text; ⌘⌫ always goes to the view. A held ⌫ that
            // empties the filter never goes on to delete.
            guard !event.isARepeat else { return query.isEmpty }
            guard query.isEmpty || flags == .command else { return false }
            return page.handle(.delete)
        // Tab would move focus out of the filter.
        case 48: return true
        // Search-only shortcuts do nothing here: actions, preview, reveal.
        default: return flags == .command && [40, 16, 15].contains(event.keyCode)
        }
    }
}
