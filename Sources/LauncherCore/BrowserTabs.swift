import Foundation

/// A browser Jevcast can read tabs from with Apple Events.
public struct Browser: Equatable, Sendable {
    /// Script dialects. Chromium browsers and Dia give tabs a stable ID; Safari tabs have only an index.
    public enum Family: Sendable { case chromium, dia, safari }
    public let bundleID: String
    public let name: String
    public let family: Family
    /// Folders under `~/Library/Application Support` that hold Chromium profiles, for history.
    public let profileRoots: [String]

    public static let all: [Browser] = [
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", family: .chromium, profileRoots: ["Google/Chrome"]),
        Browser(bundleID: "com.apple.Safari", name: "Safari", family: .safari, profileRoots: []),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", family: .chromium, profileRoots: ["Arc/User Data"]),
        Browser(bundleID: "com.brave.Browser", name: "Brave", family: .chromium, profileRoots: ["BraveSoftware/Brave-Browser"]),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", family: .chromium, profileRoots: ["Microsoft Edge"]),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", family: .chromium, profileRoots: ["Vivaldi"]),
        Browser(bundleID: "company.thebrowser.dia", name: "Dia", family: .dia, profileRoots: ["Dia/User Data"])
    ]
    public static func named(_ bundleID: String) -> Browser? { all.first { $0.bundleID == bundleID } }
}

/// One open tab.
public struct BrowserTab: Equatable, Sendable {
    public let browser: String
    /// The window's ID as text. Chrome and Dia use text IDs; Safari's are numbers.
    public let windowID: String
    /// The tab's own ID, or its 1-based index in Safari, which has no tab IDs.
    public let key: String
    public let title: String
    public let url: String
    public let active: Bool
    public init(browser: String, windowID: String, key: String, title: String, url: String, active: Bool) {
        self.browser = browser; self.windowID = windowID; self.key = key; self.title = title; self.url = url; self.active = active
    }
    public var id: String { "tab:\(browser):\(windowID):\(key)" }
    public var host: String {
        let host = URL(string: url)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    public var markdown: String { Markdown.link(title, url) }
}

public enum Markdown {
    /// `[title](url)` with brackets in the title and parentheses in the URL escaped.
    public static func link(_ title: String, _ url: String) -> String {
        let text = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let target = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(text.isEmpty ? url : text)](\(target))"
    }
}

/// The AppleScript Jevcast runs, and the parser for what it prints. Scripts are fixed text per browser
/// family. Values such as a window ID reach them as `argv`, never as script text.
public enum TabScripts {
    /// Field and record separators that page titles cannot contain.
    public static let field = "\u{1F}", record = "\u{1E}"

    /// Prints one record per tab: window ID, tab key, active flag, title, URL.
    public static func list(_ browser: Browser) -> String {
        let body: String
        switch browser.family {
        case .safari:
            body = """
                  set ci to index of current tab of w
                  set i to 0
                  repeat with t in tabs of w
                    set i to i + 1
                    set out to out & (id of w as text) & fs & i & fs & (i = ci) & fs & (name of t) & fs & (URL of t) & rs
                  end repeat
            """
        case .chromium, .dia:
            body = """
                  set aid to (id of active tab of w) as text
                  repeat with t in tabs of w
                    set tid to (id of t) as text
                    set out to out & (id of w as text) & fs & tid & fs & (tid = aid) & fs & (title of t) & fs & (URL of t) & rs
                  end repeat
            """
        }
        return """
        on run argv
          set out to ""
          set fs to (character id 31)
          set rs to (character id 30)
          with timeout of 4 seconds
            tell application id "\(browser.bundleID)"
              repeat with w in windows
                try
        \(body)
                end try
              end repeat
            end tell
          end timeout
          return out
        end run
        """
    }

    /// `argv`: window ID, tab key, expected URL. Finds the window and tab, checks the tab still shows
    /// that page, then runs `action` on `w` (the window) and `t` (the tab). Error 1001 means it changed.
    static func onTab(_ browser: Browser, _ action: String) -> String {
        let find: String
        switch browser.family {
        case .safari:
            find = """
                set t to tab ((item 2 of argv) as integer) of w
            """
        case .chromium, .dia:
            find = """
                set t to missing value
                set i to 0
                repeat with candidate in tabs of w
                  set i to i + 1
                  if ((id of candidate) as text) is (item 2 of argv) then
                    set t to candidate
                    exit repeat
                  end if
                end repeat
                if t is missing value then error "The tab is closed." number 1001
            """
        }
        return """
        on run argv
          with timeout of 4 seconds
            tell application id "\(browser.bundleID)"
              set w to missing value
              repeat with candidate in windows
                if ((id of candidate) as text) is (item 1 of argv) then
                  set w to candidate
                  exit repeat
                end if
              end repeat
              if w is missing value then error "The window is closed." number 1001
        \(find)
              if (URL of t) is not (item 3 of argv) then error "The tab changed." number 1001
        \(action)
            end tell
          end timeout
        end run
        """
    }

    /// Brings the tab and its window to the front.
    public static func focus(_ browser: Browser) -> String {
        switch browser.family {
        case .safari: return onTab(browser, "      set current tab of w to t\n      set index of w to 1\n      activate")
        case .chromium: return onTab(browser, "      set active tab index of w to i\n      set index of w to 1\n      activate")
        case .dia: return onTab(browser, "      focus t\n      activate")
        }
    }

    public static func close(_ browser: Browser) -> String { onTab(browser, "      close t") }

    /// Prints the front window's current tab: title, then URL.
    public static func frontTab(_ browser: Browser) -> String {
        let (titleKey, tab) = browser.family == .safari ? ("name", "current tab") : ("title", "active tab")
        return """
        on run argv
          with timeout of 2 seconds
            tell application id "\(browser.bundleID)"
              if (count of windows) is 0 then return ""
              set t to \(tab) of front window
              return (\(titleKey) of t) & (character id 31) & (URL of t)
            end tell
          end timeout
        end run
        """
    }

    public static func parse(_ output: String, browser: String) -> [BrowserTab] {
        output.components(separatedBy: record).compactMap { line in
            let parts = line.components(separatedBy: field)
            guard parts.count == 5 else { return nil }
            let window = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !window.isEmpty, !parts[1].isEmpty else { return nil }
            let url = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserTab(browser: browser, windowID: window, key: parts[1], title: parts[3], url: url, active: parts[2] == "true")
        }
    }

    /// True when osascript failed because the user has not allowed Apple Events to that app (-1743).
    public static func isNotAuthorized(_ message: String) -> Bool {
        message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized to send apple events")
    }

    /// True for Jevcast's own "the tab changed" error.
    public static func isStale(_ message: String) -> Bool { message.contains("(1001)") }
}

/// Visits from a Chromium `History` database, newest first.
public struct HistoryVisit: Equatable, Sendable {
    public let title: String
    public let url: String
    public let lastVisit: Date
    public let visits: Int
    public let browser: String
    public init(title: String, url: String, lastVisit: Date, visits: Int, browser: String) {
        self.title = title; self.url = url; self.lastVisit = lastVisit; self.visits = visits; self.browser = browser
    }
    /// Chromium stores microseconds since 1601-01-01 UTC.
    public static func chromiumDate(_ micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }
    /// Safari stores seconds since 2001-01-01 UTC.
    public static func safariDate(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
}
