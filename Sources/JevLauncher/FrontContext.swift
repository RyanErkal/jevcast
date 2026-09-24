import AppKit
import EventKit
import LauncherCore

/// "This": the page, files, or text in front when the launcher opened. It stays on this Mac.
/// Only a Luna action that the user turns on in Settings can send any of it.
enum FrontContext: Equatable {
    case page(title: String, url: String, browser: String)
    case files([String])
    case text(String, app: String)

    /// Reads the front app's context. Returns nil quickly when there is nothing useful.
    /// Apple Events go only to an app Jevcast may already control, unless `mayAsk` is set
    /// because the query itself asked for "this"; then macOS may ask the user once.
    @MainActor static func capture(from app: NSRunningApplication, mayAsk: Bool) async -> FrontContext? {
        let bundleID = app.bundleIdentifier ?? ""
        let scriptable = Browser.named(bundleID) != nil || bundleID == "com.apple.finder"
        var allowed = false
        if scriptable {
            switch await AppleScript.permission(for: bundleID) {
            case .granted: allowed = true
            case .notAsked: allowed = mayAsk
            case .denied, .notRunning: allowed = false
            }
        }
        if allowed, let browser = Browser.named(bundleID) {
            let output = (try? await AppleScript.run(TabScripts.frontTab(browser), app: browser.bundleID, name: browser.name)) ?? ""
            let parts = output.trimmingCharacters(in: .newlines).components(separatedBy: TabScripts.field)
            if parts.count == 2, !parts[1].isEmpty { return .page(title: parts[0], url: parts[1], browser: bundleID) }
        }
        if allowed, bundleID == "com.apple.finder" {
            let script = """
            with timeout of 2 seconds
              tell application id "com.apple.finder"
                set out to ""
                repeat with f in (selection as alias list)
                  set out to out & POSIX path of f & (character id 30)
                end repeat
                return out
              end tell
            end timeout
            """
            let output = (try? await AppleScript.run(script, app: bundleID, name: "Finder")) ?? ""
            let paths = output.components(separatedBy: TabScripts.record).map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
            if !paths.isEmpty { return .files(paths) }
        }
        if let text = selectedText(pid: app.processIdentifier), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text, app: app.localizedName ?? "the app")
        }
        return nil
    }

    /// The selected text in an app's focused element, through Accessibility.
    @MainActor static func selectedText(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        // Each element keeps its own timeout, so a slow app cannot hold the launcher.
        AXUIElementSetMessagingTimeout(element, 0.25)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        return (selected as? String).map { String($0.prefix(20_000)) }
    }

    /// What the rows show as "this": the page title, the file names, or the start of the text.
    var summary: String {
        switch self {
        case .page(let title, let url, _): return title.isEmpty ? url : title
        case .files(let paths):
            let names = paths.prefix(3).map { ($0 as NSString).lastPathComponent }
            return names.joined(separator: ", ") + (paths.count > 3 ? " and \(paths.count - 3) more" : "")
        case .text(let text, _):
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return "“" + (line.count > 60 ? String(line.prefix(60)) + "…" : line) + "”"
        }
    }
}

extension LauncherModel {
    static let thisWords: Set<String> = ["this", "this page", "this file", "these files", "selection", "selected text", "context"]

    /// Rows that act on "this". A normal search matches their titles, below apps and commands;
    /// the word "this" lists them all.
    func contextRows(_ q: String) -> [LauncherResult] {
        guard let frontContext else { return [] }
        let lower = q.lowercased()
        let all = contextActions(frontContext)
        let showAll = Self.thisWords.contains(lower)
        return all.compactMap { row in
            if showAll { var row = row; row.score = 1600 - Double(all.firstIndex { $0.id == row.id } ?? 0); return row }
            guard lower.count >= 3, let score = SearchRanking.score(query: q, title: row.title) else { return nil }
            var row = row; row.score = score * 100 - 2; return row
        }
    }

    /// Every "this" row, for Jev and for a remembered pick.
    func allContextRows() -> [LauncherResult] { frontContext.map(contextActions) ?? [] }

    private func contextActions(_ context: FrontContext) -> [LauncherResult] {
        let detail = context.summary
        func row(_ id: String, _ title: String, _ symbol: String, jev: String, verb: Verb) -> LauncherResult {
            LauncherResult(id: "this:" + id, title: title, detail: detail, symbol: symbol,
                           action: .thing(Thing(verbs: [verb], twoLine: false, jevDetail: jev)), score: 0)
        }
        var rows: [LauncherResult] = []
        switch context {
        case .page(let title, let url, let browser):
            rows.append(row("copy-link", "Copy Link to This Page", "link", jev: "Copy the URL of the page open in the browser",
                            verb: Verb(title: "Copy Link", after: .close) { copyText(url); return nil }))
            rows.append(row("copy-markdown", "Copy This Page as a Markdown Link", "link", jev: "Copy the open page as a Markdown link",
                            verb: Verb(title: "Copy Link", after: .close) { copyText(Markdown.link(title, url)); return nil }))
            rows.append(row("remind-page", "Remind Me About This Page Tomorrow", "checklist", jev: "Make a reminder for tomorrow about the open web page",
                            verb: Verb(title: "Add Reminder", after: .close) {
                                try await Self.addReminder(CreateQuery(kind: .reminder, title: title.isEmpty ? url : title,
                                                                       date: Self.tomorrowMorning(), hasTime: true), url: URL(string: url))
                                return nil
                            }))
            for other in Browser.all where other.bundleID != browser {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: other.bundleID), let link = URL(string: url) else { continue }
                rows.append(row("open-in:" + other.bundleID, "Open This Page in \(other.name)", "arrow.up.forward.app",
                                jev: "Open the current web page in the \(other.name) browser",
                                verb: Verb(title: "Open") {
                                    _ = try await NSWorkspace.shared.open([link], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                                    return nil
                                }))
            }
        case .files(let paths):
            let noun = paths.count == 1 ? "File" : "Files"
            rows.append(row("copy-paths", "Copy Paths of Selected \(noun)", "doc.on.doc", jev: "Copy the paths of the files selected in Finder",
                            verb: Verb(title: "Copy Paths", after: .close) { copyText(paths.joined(separator: "\n")); return nil }))
            rows.append(row("compress", "Compress Selected \(noun)", "doc.zipper", jev: "Make a zip archive of the files selected in Finder",
                            verb: Verb(title: "Compress", after: .close) { try await Self.compress(paths); return nil }))
            rows.append(row("remind-file", "Remind Me About This \(noun) Tomorrow", "checklist", jev: "Make a reminder for tomorrow about the selected files",
                            verb: Verb(title: "Add Reminder", after: .close) {
                                let name = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
                                try await Self.addReminder(CreateQuery(kind: .reminder, title: "Look at " + name, date: Self.tomorrowMorning(), hasTime: true),
                                                           url: paths.count == 1 ? URL(fileURLWithPath: paths[0]) : nil)
                                return nil
                            }))
        case .text(let text, _):
            rows.append(row("search-text", "Search the Web for Selected Text", "magnifyingglass", jev: "Search the web for the text selected in the front app",
                            verb: Verb(title: "Search") {
                                var components = URLComponents(string: self.preferences.webEngine == "DuckDuckGo" ? "https://duckduckgo.com/" : "https://www.google.com/search")!
                                components.queryItems = [URLQueryItem(name: "q", value: String(text.prefix(500)))]
                                if let url = components.url { NSWorkspace.shared.open(url) }
                                return nil
                            }))
            rows.append(row("remind-text", "Remind Me About Selected Text Tomorrow", "checklist", jev: "Make a reminder for tomorrow with the selected text",
                            verb: Verb(title: "Add Reminder", after: .close) {
                                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                                try await Self.addReminder(CreateQuery(kind: .reminder, title: String(line.prefix(120)), date: Self.tomorrowMorning(), hasTime: true))
                                return nil
                            }))
        }
        return rows + lunaRows(context)
    }

    static func tomorrowMorning() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Zips the files beside the first one, as Finder's Compress does, without a shell.
    static func compress(_ paths: [String]) async throws {
        guard let first = paths.first else { return }
        let folder = (first as NSString).deletingLastPathComponent
        // zip names each file relative to one folder, so every file must be in it.
        guard paths.allSatisfy({ ($0 as NSString).deletingLastPathComponent == folder }) else {
            throw LauncherError("Select files from one folder to compress them together.")
        }
        if paths.count == 1 {
            let name = ((first as NSString).lastPathComponent as NSString).deletingPathExtension
            _ = try await CommandRunner.capture(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", first,
                                                 uniquePath(folder + "/" + name, extension: "zip")])
        } else {
            let names = paths.map { ($0 as NSString).lastPathComponent }
            // "./" keeps a name that starts with "-" from reading as an option.
            _ = try await CommandRunner.capture(["/usr/bin/zip", "-r", "-q", uniquePath(folder + "/Archive", extension: "zip")] + names.map { "./" + $0 },
                                                currentDirectory: folder)
        }
    }

    static func uniquePath(_ base: String, extension ext: String) -> String {
        var candidate = base + "." + ext, number = 2
        while FileManager.default.fileExists(atPath: candidate) { candidate = "\(base) \(number).\(ext)"; number += 1 }
        return candidate
    }
}

extension LauncherModel {
    /// Reads "this" once the user starts typing, not when the panel opens. A query that names
    /// "this" may ask macOS for Automation access; other queries use only access already given.
    func loadContextIfNeeded(_ q: String) {
        guard let app = contextApp, app.processIdentifier != getpid(), !q.isEmpty else { return }
        let asks = Self.thisWords.contains(q.lowercased())
        guard contextState == .none || (contextState == .withoutAsking && asks) else { return }
        contextState = asks ? .asked : .withoutAsking
        let current = visibleSession
        Task { @MainActor [weak self] in
            let context = await FrontContext.capture(from: app, mayAsk: asks)
            guard let self, self.visible, self.visibleSession == current else { return }
            if context != nil || self.frontContext == nil { self.frontContext = context }
            if !self.query.isEmpty { self.rebuild() }
        }
    }
}
