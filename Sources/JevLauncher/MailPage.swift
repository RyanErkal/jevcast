import AppKit
import Combine
import SwiftUI
import LauncherCore

/// Mail lives only in the launcher panel: the mailbox sidebar, the message list, and the selected
/// message or the open draft. ↑↓ move and preview, a message you move to is marked read, Return or
/// a double click reads it across the panel, Space pages through it, ⌫ deletes, and ⌘N writes a
/// new message. Letters always type in the filter, so replies use Apple Mail's keys: ⌘R, ⇧⌘R, and
/// ⇧⌘F to forward. A reply is written in the panel: the panel is the key window, so text boxes
/// take typing without activating the app.
@MainActor
final class MailPage: ObservableObject, LauncherPage {
    let id = ViewID.mail
    /// Nil for snapshot runs, which show the empty inbox and never read Mail.
    let mail: MailModel?
    /// Gives the keys back to the filter field, such as after the composer closes.
    let focusFilter: (() -> Void)?
    /// Empties the launcher's search field, which is Mail's filter.
    let clearQuery: (() -> Void)?
    let accountCenter: NativeMailCenter
    let features: MailFeatureCenter?
    @Published var tool: MailTool?
    @Published var accountDetailsID: String?
    /// A kept draft stays in the model but steps aside, such as after Escape or while another
    /// message shows. The model holds it, so Mail opens again as you left it.
    var draftHidden: Bool {
        get { mail?.draftSetAside ?? false }
        set { if mail?.draftSetAside != newValue { mail?.draftSetAside = newValue } }
    }
    /// The message fills the panel and the sidebar and list hide. Escape shows them again first.
    @Published var expanded = false
    /// The mailbox sidebar. The list's button hides it for more room; it stays as you left it.
    @Published var showsSidebar: Bool {
        didSet { sidebarDefaults?.set(showsSidebar, forKey: MailReading.sidebarKey) }
    }
    /// The sidebar's width you dragged to, or nil for the width that follows the panel.
    @Published var sidebarWidth: CGFloat?
    /// The list's width you dragged to, for each reading `Split`. Each layout keeps its own;
    /// double-clicking the divider goes back to the width that follows the panel for that layout.
    @Published private(set) var listWidths: [MailReading.Split: CGFloat] = [:]
    /// Whether the composer's formatting bar shows.
    let composerPreferences: MailComposerPreferences
    /// Where the sidebar, column, and composer choices are kept. Nil for snapshots and tests,
    /// which keep nothing.
    let sidebarDefaults: UserDefaults?
    /// An empty model for snapshot runs, which never read Mail.
    private lazy var empty = MailModel(aiWriting: { _ in throw CancellationError() }, aiWritingAllowed: { false })

    private var draftWatch: AnyCancellable?
    /// True while the focused text field, such as the launcher's filter, has text selected.
    var hasTextSelection: () -> Bool = { MailPage.selectsText(NSApp.keyWindow?.firstResponder) }

    /// True when `responder` is a text field's editor with a non-empty selection.
    static func selectsText(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView else { return false }
        return editor.selectedRanges.contains { $0.rangeValue.length > 0 }
    }

    init(mail: MailModel?, focusFilter: (() -> Void)? = nil, clearQuery: (() -> Void)? = nil, accountCenter: NativeMailCenter? = nil,
         features: MailFeatureCenter? = nil, sidebarDefaults: UserDefaults? = nil) {
        self.mail = mail; self.focusFilter = focusFilter; self.clearQuery = clearQuery
        self.features = features
        self.sidebarDefaults = sidebarDefaults
        showsSidebar = sidebarDefaults?.object(forKey: MailReading.sidebarKey) as? Bool ?? true
        sidebarWidth = (sidebarDefaults?.object(forKey: MailReading.sidebarWidthKey) as? Double).map { CGFloat($0) }
        listWidths = Self.storedListWidths(sidebarDefaults)
        composerPreferences = MailComposerPreferences(defaults: sidebarDefaults)
        self.accountCenter = accountCenter ?? (UISnapshots.directory == nil ? .shared : NativeMailCenter(backend: .jevcast, defaults: nil))
        // A new draft, such as from the reader's Reply button, shows at once. So does the open
        // draft when a new one was refused or the open one was picked again.
        guard let mail else { return }
        let newDraft = mail.$draft.map { $0?.id }.removeDuplicates().dropFirst().map { _ in () }
        draftWatch = newDraft.merge(with: mail.$draftNudge.dropFirst().map { _ in () })
            .sink { [weak self] in MainActor.assumeIsolated { self?.tool = nil; self?.accountDetailsID = nil; self?.draftHidden = false } }
    }

    private var model: MailModel { mail ?? empty }
    var isTyping: Bool { composing || accountDetailsID != nil || tool != nil }
    /// True while the composer is on screen.
    var composing: Bool { tool == nil && accountDetailsID == nil && mail?.draft != nil && !draftHidden }
    var openTitle: String { mail?.place != .outbox && mail?.selected != nil ? "Read" : "" }

    /// Mail opens where you left it in this session: the same mailbox and message, or the newest
    /// message when that one is gone. A message picked in the search, or a mail link, moves there
    /// after this. The message on screen stays unread until you act on it.
    func opened() {
        guard let mail else { return }
        mail.start()
        resume()
    }

    /// Opening, apart from starting the watch on Mail's index: the place and message stay.
    func resume() {
        guard let mail else { return }
        mail.treatSelectionAsAutomatic()
        expanded = MailReading.split == .messageOnly
        // The preview is always on screen, so a message you move to counts as read after a moment.
        mail.windowIsKey = true
    }

    /// Mail on the inbox, such as for a search from an invitation in Calendar.
    func showInbox() {
        mail?.place = .inbox
    }
    func closed(handingOff: Bool) {
        guard let mail else { return }
        mail.windowIsKey = false
        if mail.discardArmed { mail.discardArmed = false; mail.composeNote = nil }
        expanded = false
        // An open reply stays in the model, so the next visit shows it.
        mail.stop()
    }

    /// Opens one message, such as a row picked in the search.
    /// The message counts as read only once it loads and is selected, not the one selected before.
    /// You asked for this message, so nothing may hide it: the launcher's search text goes (it
    /// would filter it out), and connection details or a tool close.
    func show(_ rowID: Int64) {
        guard let mail, mail.open(rowID) else { return }
        tool = nil; accountDetailsID = nil
        if !mail.search.isEmpty {
            if let clearQuery { clearQuery() } else { filter("") }
        }
        mail.windowIsKey = true
        keepDraft()
    }

    /// A message clicked in the list. An open draft steps aside and is kept; its note opens it again.
    func pick(_ rowID: Int64) {
        accountDetailsID = nil
        guard let mail else { return }
        mail.select(rowID, byUser: true)
        keepDraft()
        // A click gives the list the keys; letters type in the filter again.
        if !composing { DispatchQueue.main.async { [weak self] in self?.focusFilter?() } }
    }

    /// A plain click on a row, also on the row already selected. When the click changed the
    /// selection, `pick` already ran; otherwise this shows the row and closes what covers the
    /// reader, such as connection details or a draft.
    func activate(_ rowID: Int64) {
        guard let mail else { return }
        if mail.selectedConversationRowIDs == [rowID], mail.selectedConversationRowID == rowID, accountDetailsID == nil, !composing { return }
        pick(rowID)
    }

    /// Return or a double click: the selected message across the panel, counted as read. It never
    /// opens Apple Mail; Open in Mail is in the ⋯ menu.
    func read(_ rowID: Int64? = nil) {
        guard let mail else { return }
        if let rowID { pick(rowID) }
        guard mail.place != .outbox, let selected = mail.selectedID else { return }
        mail.select(selected, byUser: true)
        expanded = true
    }

    /// The open draft closes as Escape closes it: saved, with a note that opens it again, or
    /// dropped when it is still exactly as Jevcast filled it in.
    private func keepDraft() {
        guard let mail, mail.draft != nil, !draftHidden else { return }
        mail.closeDraft()
    }

    /// The filter only narrows the list. A message the filter selects by itself counts as read once
    /// the filter stops changing, since its first match changes as you type.
    func filter(_ text: String) {
        guard let mail, mail.search != text else { return }
        mail.search = text
    }

    func handle(_ key: PageKey) -> Bool {
        guard accountDetailsID == nil, tool == nil else { return false }
        guard let mail else { return true }
        switch key {
        case .down: mail.moveSelection(1)
        case .up: mail.moveSelection(-1)
        case .open: read()
        case .delete: mail.delete()
        case .left, .right: return false
        }
        return true
    }

    /// Space pages down through the message while the filter is empty, and goes to the next
    /// message at its end; ⇧Space pages up. ⌘+, ⌘−, and ⌘0 change the text size. ⌘N writes a new
    /// message, ⌘R replies, ⇧⌘R replies to all, and ⇧⌘F forwards, as in Apple Mail; plain letters
    /// always type in the filter. Keys are read as characters, so they match the key caps on every layout.
    func handleEvent(_ event: NSEvent) -> Bool {
        // ⇧⌘⌫ is Discard while writing. With no composer open it does nothing here, so a second
        // press after Discard closed a draft never reaches Delete.
        if Self.isDiscardKey(event) { return true }
        guard let mail, !isTyping else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "z" {
            switch mail.undoKeyTarget {
            case .send: mail.undoSend(); return true
            case .change: mail.undoLastChange(); return true
            case .none: break
            }
        }
        if flags == .command, key == "n" { mail.compose(); return true }
        if flags == .command, key == "k" { MailActionsMenu.show(self, mail); return true }
        if let change = Self.zoomChange(key, flags) {
            MailReading.zoom = MailReading.zoom(MailReading.zoom, change)
            return true
        }
        if flags == .command, let key, let digit = Int(key), (1...Self.places.count).contains(digit) {
            mail.place = Self.places[digit - 1]
            return true
        }
        guard mail.place != .outbox, mail.selected != nil else { return false }
        if key == " ", flags.isEmpty || flags == .shift, mail.search.isEmpty {
            // Scrolling the message counts as reading it.
            mail.noteUserAction()
            mail.readerScroll.page(down: flags.isEmpty) { [weak mail] in mail?.moveSelection(1) }
            return true
        }
        switch (key, flags) {
        case ("r", .command): mail.reply(all: false)
        case ("r", [.command, .shift]): mail.reply(all: true)
        case ("f", [.command, .shift]): mail.forward()
        // The same keys as Apple Mail: archive, flag, read or unread, junk. ⇧⌘M opens the folders to move to.
        // ⌘E is a shorter key for Archive, except while text is selected in the filter: there it
        // is the text's own Use Selection for Find. ⌃⌘A always archives.
        case ("e", .command) where hasTextSelection(): return false
        case ("a", [.command, .control]), ("e", .command): mail.archive()
        case ("l", [.command, .shift]): mail.toggleFlag()
        case ("u", [.command, .shift]): mail.toggleRead()
        case ("j", [.command, .shift]): mail.setJunk(!mail.selectedIsJunk)
        case ("m", [.command, .shift]): MailMoveMenu.show(mail)
        case ("s", [.command, .control]): openSnooze()
        default: return false
        }
        return true
    }

    /// ⌘+ (or ⌘=) one step larger, ⌘− one step smaller, ⌘0 actual size. Nil for any other key.
    static func zoomChange(_ key: String?, _ flags: NSEvent.ModifierFlags) -> MailReading.ZoomChange? {
        guard flags == .command || flags == [.command, .shift] else { return nil }
        switch key {
        case "+", "=": return .larger
        case "-", "−": return .smaller
        case "0": return flags == .command ? .actualSize : nil
        default: return nil
        }
    }

    /// Opens a Mail Settings page, such as Rules. Escape comes back.
    func openTool(_ page: MailTool) {
        tool = page
        features?.refresh(full: true)
    }

    /// Snooze from a row's menu. The row shows in the reader first, as a click shows it (an open
    /// draft steps aside by the usual rules), so the Snooze popover has the reader's bar to open from.
    func snoozeRow(_ rowID: Int64) {
        pick(rowID)
        DispatchQueue.main.async { [weak self] in self?.openSnooze() }
    }

    /// Opens Snooze for the message on screen. Snooze is for Jevcast's own accounts.
    func openSnooze() {
        guard let mail, let message = mail.selected, !mail.refuses(.snooze) else { return }
        let account = mail.actionBox(message)?.accountID
        guard let features, features.accountChoices.contains(where: { $0.id == account }) else {
            mail.banner = "Snooze works with the accounts you add in Settings › Mail."
            return
        }
        tool = nil; accountDetailsID = nil
        mail.snoozeEditorOpen = true
    }

    /// ⇧⌘⌫ while writing: Discard, with the same second press as the Discard button. A held key
    /// repeats nothing: the second press must be a new one. ⌘⌫ stays with the text, where it
    /// deletes to the start of the line; ⇧⌘⌫ has no binding in text fields. ⇧⌘A attaches files,
    /// as in Apple Mail. The formatting keys belong to the text itself.
    func handleTypingEvent(_ event: NSEvent) -> Bool {
        // Taken also in Mail Settings pages and connection details, where it does nothing.
        if Self.isDiscardKey(event) {
            if composing, !event.isARepeat { mail?.discardDraft() }
            return true
        }
        guard composing, let mail else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "a" { mail.pickAttachments(); return true }
        return false
    }

    /// The Delete (backspace) key.
    static let deleteKey: UInt16 = 51

    /// ⇧⌘⌫, the Discard key, with no other modifier.
    static func isDiscardKey(_ event: NSEvent) -> Bool {
        event.keyCode == deleteKey && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .shift]
    }

    // MARK: Column widths

    /// The list width you dragged to under this reading setting.
    func customListWidth(for split: MailReading.Split) -> CGFloat? { listWidths[split] }

    /// A divider moved. The width is kept once the drag ends (`keepColumnWidths`).
    func dragSidebar(to width: CGFloat) { sidebarWidth = width }
    func dragList(to width: CGFloat, split: MailReading.Split) { listWidths[split] = width }

    func keepColumnWidths() {
        guard let defaults = sidebarDefaults else { return }
        if let sidebarWidth { defaults.set(Double(sidebarWidth), forKey: MailReading.sidebarWidthKey) }
        else { defaults.removeObject(forKey: MailReading.sidebarWidthKey) }
        for split in MailReading.Split.allCases {
            let key = MailReading.listWidthKey(split)
            if let width = listWidths[split] { defaults.set(Double(width), forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        // The one width of earlier builds now lives under its layout's own key.
        defaults.removeObject(forKey: MailReading.legacyListWidthKey)
        defaults.removeObject(forKey: MailReading.legacyListWidthSplitKey)
    }

    /// The kept list widths, by layout. A width kept by an earlier build counts for the layout it
    /// was dragged under.
    static func storedListWidths(_ defaults: UserDefaults?) -> [MailReading.Split: CGFloat] {
        guard let defaults else { return [:] }
        var widths: [MailReading.Split: CGFloat] = [:]
        for split in MailReading.Split.allCases {
            if let width = defaults.object(forKey: MailReading.listWidthKey(split)) as? Double { widths[split] = CGFloat(width) }
        }
        if let width = defaults.object(forKey: MailReading.legacyListWidthKey) as? Double,
           let split = defaults.string(forKey: MailReading.legacyListWidthSplitKey).flatMap(MailReading.Split.init(rawValue:)), widths[split] == nil {
            widths[split] = CGFloat(width)
        }
        return widths
    }

    /// A double click on a divider: that column follows the panel again, for this layout only.
    func resetSidebarWidth() { sidebarWidth = nil; keepColumnWidths() }
    func resetListWidth(for split: MailReading.Split) { listWidths[split] = nil; keepColumnWidths() }

    /// ⌘1 to ⌘7 open Inbox, All Mail, Unread, Flagged, Drafts, Sent, and Outbox.
    private static let places: [MailModel.Place] = [.inbox, .allMail, .unread, .flagged, .drafts, .sent, .outbox]

    var footerHints: [(title: String, key: String)] {
        if accountDetailsID != nil || tool != nil { return [] }
        // The composer shows Send and its key itself; the footer adds the keys it does not show.
        if isTyping { return [("Attach", "⇧⌘A"), ("Discard", "⇧⌘⌫")] }
        guard mail?.place != .outbox, mail?.selected != nil else { return [("New", "⌘N")] }
        // The few keys used most. ⌘K lists every action with its key.
        return [("Reply", "⌘R"), ("Archive", "⌘E"), ("Actions", "⌘K")]
    }
    /// Escape while writing closes the composer and keeps the draft; an empty one just closes.
    var backTitle: String? {
        if accountDetailsID != nil || tool != nil { return "Mail" }
        guard isTyping else { return nil }
        return mail?.draft?.needsKeeping == true ? "Save Draft" : "Close"
    }
    var footerChanges: AnyPublisher<Void, Never> {
        let own = objectWillChange.map { _ in () }
        guard let mail else { return own.eraseToAnyPublisher() }
        return own.merge(with: mail.objectWillChange.map { _ in () }).eraseToAnyPublisher()
    }

    /// Escape never deletes a draft: it closes the composer and keeps the draft in Drafts, with a
    /// note that opens it again. An empty, untouched draft just closes. Then Escape leaves the
    /// expanded message, then a selection of several rows narrows to the message on screen, and
    /// only then does Escape leave Mail. Each press undoes the innermost thing on screen.
    func back() -> Bool {
        if tool != nil { tool = nil; return true }
        if accountDetailsID != nil { accountDetailsID = nil; return true }
        if let mail, mail.draft != nil, !draftHidden {
            mail.closeDraft()
            return true
        }
        if expanded { expanded = false; return true }
        if let mail, mail.narrowSelection() { return true }
        return false
    }

    func content() -> AnyView { AnyView(MailPageView(page: self, mail: model, center: accountCenter, snapshot: mail == nil)) }
}

private struct MailPageView: View {
    @ObservedObject var page: MailPage
    @ObservedObject var mail: MailModel
    @ObservedObject var center: NativeMailCenter
    let snapshot: Bool

    var body: some View {
        Group {
            if ready { MailWorkspace(page: page, mail: mail) } else { MailSetupView(model: mail, needsAccess: needsAccess) }
        }
        // The filter takes the keys again once the composer closes or steps aside, or a mailbox is picked.
        .onChange(of: page.composing) { _, now in if !now { DispatchQueue.main.async { page.focusFilter?() } } }
        .onChange(of: mail.place) { _, _ in
            page.accountDetailsID = nil
            if !page.composing { DispatchQueue.main.async { page.focusFilter?() } }
        }
        .modifier(MailFolderPrompt(model: mail))
        .modifier(MailSenderDeletePrompt(model: mail))
        // Above the composer's footer while one is open, so the note never covers Send.
        .overlay(alignment: .bottom) {
            MailBanner(model: mail, typing: page.isTyping).padding(.bottom, page.composing ? 58 : 12)
                .animation(MailStyle.motion, value: mail.lastChange?.id).animation(MailStyle.motion, value: mail.banner)
                .animation(MailStyle.motion, value: mail.draftNote)
        }
    }

    private var ready: Bool {
        if snapshot || (center.backend == .jevcast && !center.accounts.isEmpty) { return true }
        if case .ready = mail.status { return true }
        return false
    }
    private var needsAccess: Bool { if case .needsFullDiskAccess = mail.status { return true }; return false }
}
