import AppKit
import LauncherCore

/// Runs Jevcast's fixed AppleScript with `osascript`. Values go in as arguments. A refusal
/// becomes a `SourceProblem` whose button opens the Automation settings.
enum AppleScript {
    static func run(_ script: String, _ arguments: [String] = [], app bundleID: String, name: String) async throws -> String {
        do { return try await CommandRunner.capture(["/usr/bin/osascript", "-e", script] + arguments) }
        catch let failure as CommandRunner.Failure where TabScripts.isNotAuthorized(failure.text) {
            throw SourceProblem(text: "Allow Jevcast to control \(name) in Privacy & Security › Automation.", access: .automation(bundleID))
        }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Open tabs in every running browser that Jevcast supports. It never starts a browser.
@MainActor
final class TabsSource: ThingSource {
    let section = "Open Tabs"

    func load(_ filter: String) async throws -> [LauncherResult] {
        let running = Browser.all.filter { AppleScript.isRunning($0.bundleID) }
        guard !running.isEmpty else { throw SourceProblem(text: "No supported browser is open. Jevcast reads tabs from Safari, Chrome, Arc, Brave, Edge, Vivaldi, and Dia.") }
        var tabs: [BrowserTab] = [], problems: [Error] = []
        await withTaskGroup(of: Result<[BrowserTab], Error>.self) { group in
            for browser in running {
                group.addTask {
                    do {
                        let output = try await AppleScript.run(TabScripts.list(browser), app: browser.bundleID, name: browser.name)
                        return .success(TabScripts.parse(output, browser: browser.bundleID))
                    } catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result { case .success(let found): tabs += found; case .failure(let error): problems.append(error) }
            }
        }
        if tabs.isEmpty, let problem = problems.first { throw problem }
        let matching = filter.isEmpty ? tabs : tabs.filter { SearchRanking.score(query: filter, title: $0.title, aliases: [$0.host, $0.url]) != nil }
        var rows: [LauncherResult] = []
        let duplicates = Self.duplicates(tabs)
        if filter.isEmpty, !duplicates.isEmpty {
            let verb = Verb(title: "Close \(duplicates.count) Duplicate Tab" + (duplicates.count == 1 ? "" : "s"), after: .stay) {
                try await Self.close(duplicates); return "Closed \(duplicates.count) duplicate tab" + (duplicates.count == 1 ? "." : "s.")
            }
            rows.append(LauncherResult(id: "tabs:duplicates", title: verb.title, detail: "Keeps the first copy of each page",
                                       symbol: "square.on.square.dashed", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 4000))
        }
        rows += matching.prefix(80).enumerated().map { index, tab in row(tab, score: 3000 - Double(index)) }
        return rows
    }

    private func row(_ tab: BrowserTab, score: Double) -> LauncherResult {
        let browser = Browser.named(tab.browser)
        let name = browser?.name ?? "Browser"
        let verbs = [
            Verb(title: "Switch to Tab") {
                guard let browser else { return nil }
                _ = try await AppleScript.run(TabScripts.focus(browser), [String(tab.windowID), String(tab.index)], app: browser.bundleID, name: name)
                return nil
            },
            Verb(title: "Close Tab", after: .stay) {
                try await Self.close([tab]); return "Closed \(tab.title.isEmpty ? tab.host : tab.title)."
            },
            Verb(title: "Copy URL", after: .stay) { copyText(tab.url); return "URL copied." },
            Verb(title: "Copy as Markdown Link", after: .stay) { copyText(tab.markdown); return "Link copied." }
        ]
        let detail = [tab.host, name, tab.active ? "front tab" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return LauncherResult(id: tab.id, title: tab.title.isEmpty ? tab.url : tab.title, detail: detail, symbol: "safari",
                              action: .thing(Thing(verbs: verbs)), score: score)
    }

    /// Every tab whose URL an earlier tab already has.
    static func duplicates(_ tabs: [BrowserTab]) -> [BrowserTab] {
        var seen = Set<String>()
        return tabs.filter { tab in !tab.url.isEmpty && !seen.insert(tab.url).inserted }
    }

    /// Closes tabs from the highest index down, so earlier indexes stay valid.
    static func close(_ tabs: [BrowserTab]) async throws {
        for tab in tabs.sorted(by: { ($0.browser, $0.windowID, $1.index) < ($1.browser, $1.windowID, $0.index) }) {
            guard let browser = Browser.named(tab.browser) else { continue }
            _ = try await AppleScript.run(TabScripts.close(browser), [String(tab.windowID), String(tab.index)], app: browser.bundleID, name: browser.name)
        }
    }
}

/// Pages from browser history. Chromium browsers keep history where Jevcast can read a copy;
/// Safari's history needs Full Disk Access.
@MainActor
final class HistorySource: ThingSource {
    let section = "Browser History"

    func load(_ filter: String) async throws -> [LauncherResult] {
        let (visits, safariBlocked) = await Task.detached(priority: .userInitiated) { Self.search(filter) }.value
        if visits.isEmpty && safariBlocked {
            throw SourceProblem(text: "Safari history needs Full Disk Access for Jevcast.", access: .fullDiskAccess)
        }
        return visits.prefix(60).enumerated().map { index, visit in row(visit, score: 3000 - Double(index)) }
    }

    private func row(_ visit: HistoryVisit, score: Double) -> LauncherResult {
        let host = URL(string: visit.url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        let browser = Browser.named(visit.browser)
        let verbs = [
            Verb(title: "Open in " + (browser?.name ?? "Browser")) {
                guard let url = URL(string: visit.url) else { return nil }
                if let browser, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else { NSWorkspace.shared.open(url) }
                return nil
            },
            Verb(title: "Copy URL", after: .stay) { copyText(visit.url); return "URL copied." },
            Verb(title: "Copy as Markdown Link", after: .stay) { copyText("[\(visit.title)](\(visit.url))"); return "Link copied." }
        ]
        let detail = [host, visit.lastVisit.formatted(.relative(presentation: .named)), browser?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return LauncherResult(id: "history:" + visit.url, title: visit.title.isEmpty ? visit.url : visit.title, detail: detail,
                              symbol: "clock", action: .thing(Thing(verbs: verbs)), score: score)
    }

    /// Searches a private copy of each History database, newest visits first, one row per URL.
    nonisolated static func search(_ text: String) -> ([HistoryVisit], safariBlocked: Bool) {
        let support = NSHomeDirectory() + "/Library/Application Support/"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-history-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pattern = SQLiteReader.likePattern(text)
        var visits: [HistoryVisit] = []
        for browser in Browser.all where browser.family == .chromium {
            for root in browser.profileRoots {
                let folder = support + root
                for profile in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where profile == "Default" || profile.hasPrefix("Profile ") {
                    let source = folder + "/" + profile + "/History"
                    guard FileManager.default.fileExists(atPath: source) else { continue }
                    let copy = temp.appendingPathComponent(UUID().uuidString).path
                    guard (try? FileManager.default.copyItem(atPath: source, toPath: copy)) != nil,
                          let db = try? SQLiteReader(path: copy, immutable: true) else { continue }
                    let sql = "SELECT url, title, last_visit_time, visit_count FROM urls WHERE hidden = 0 AND (title LIKE ?1 ESCAPE '\\' OR url LIKE ?1 ESCAPE '\\') ORDER BY last_visit_time DESC LIMIT 80"
                    for row in (try? db.rows(sql, [.text(pattern)])) ?? [] where row.count == 4 {
                        guard let url = row[0].text, !url.isEmpty else { continue }
                        visits.append(HistoryVisit(title: row[1].text ?? "", url: url, lastVisit: HistoryVisit.chromiumDate(row[2].int ?? 0),
                                                   visits: Int(row[3].int ?? 0), browser: browser.bundleID))
                    }
                }
            }
        }
        var safariBlocked = false
        let safari = NSHomeDirectory() + "/Library/Safari/History.db"
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Safari") {
            let sql = """
            SELECT i.url, v.title, MAX(v.visit_time), i.visit_count FROM history_items i JOIN history_visits v ON v.history_item = i.id
            WHERE (v.title LIKE ?1 ESCAPE '\\' OR i.url LIKE ?1 ESCAPE '\\') GROUP BY i.id ORDER BY MAX(v.visit_time) DESC LIMIT 80
            """
            // Without Full Disk Access the file looks readable, but opening or reading it fails.
            if let db = try? SQLiteReader(path: safari), let found = try? db.rows(sql, [.text(pattern)]) {
                for row in found where row.count == 4 {
                    guard let url = row[0].text else { continue }
                    visits.append(HistoryVisit(title: row[1].text ?? "", url: url, lastVisit: HistoryVisit.safariDate(row[2].double ?? 0),
                                               visits: Int(row[3].int ?? 0), browser: "com.apple.Safari"))
                }
            } else { safariBlocked = true }
        }
        var seen = Set<String>()
        let sorted = visits.sorted { $0.lastVisit > $1.lastVisit }.filter { seen.insert($0.url).inserted }
        return (sorted, safariBlocked)
    }
}
