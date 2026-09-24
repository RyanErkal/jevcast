import Foundation

/// A browser Jevcast can read tabs from with Apple Events.
public struct Browser: Equatable, Sendable {
    public enum Family: Sendable { case chromium, safari }
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
        Browser(bundleID: "company.thebrowser.dia", name: "Dia", family: .chromium, profileRoots: ["Dia/User Data"])
    ]
    public static func named(_ bundleID: String) -> Browser? { all.first { $0.bundleID == bundleID } }
}

/// One open tab.
public struct BrowserTab: Equatable, Sendable {
    public let browser: String
    public let windowID: Int
    /// 1-based, as AppleScript counts.
    public let index: Int
    public let title: String
    public let url: String
    public let active: Bool
    public init(browser: String, windowID: Int, index: Int, title: String, url: String, active: Bool) {
        self.browser = browser; self.windowID = windowID; self.index = index; self.title = title; self.url = url; self.active = active
    }
    public var id: String { "tab:\(browser):\(windowID):\(index)" }
    public var host: String {
        let host = URL(string: url)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    public var markdown: String { "[\(title.replacingOccurrences(of: "]", with: "\\]"))](\(url))" }
}

/// The AppleScript Jevcast runs, and the parser for what it prints. Scripts are fixed text per browser
/// family. Values such as a window ID reach them as `argv`, never as script text.
public enum TabScripts {
    /// Field and record separators that page titles cannot contain.
    public static let field = "\u{1F}", record = "\u{1E}"

    /// Prints one record per tab: window ID, tab index, active flag, title, URL.
    public static func list(_ browser: Browser) -> String {
        let (titleKey, activeTest) = browser.family == .safari
            ? ("name", "(i = (index of current tab of w))")
            : ("title", "(i = (active tab index of w))")
        return """
        on run argv
          set out to ""
          set fs to (character id 31)
          set rs to (character id 30)
          with timeout of 4 seconds
            tell application id "\(browser.bundleID)"
              repeat with w in windows
                try
                  set wid to id of w
                  set i to 0
                  repeat with t in tabs of w
                    set i to i + 1
                    set out to out & wid & fs & i & fs & \(activeTest) & fs & (\(titleKey) of t) & fs & (URL of t) & rs
                  end repeat
                end try
              end repeat
            end tell
          end timeout
          return out
        end run
        """
    }

    /// `argv`: window ID, tab index. Brings the tab and its window to the front.
    public static func focus(_ browser: Browser) -> String {
        let select = browser.family == .safari
            ? "set current tab of w to tab (item 2 of argv as integer) of w"
            : "set active tab index of w to (item 2 of argv as integer)"
        return """
        on run argv
          with timeout of 4 seconds
            tell application id "\(browser.bundleID)"
              set w to window id (item 1 of argv as integer)
              \(select)
              set index of w to 1
              activate
            end tell
          end timeout
        end run
        """
    }

    /// `argv`: window ID, tab index.
    public static func close(_ browser: Browser) -> String {
        """
        on run argv
          with timeout of 4 seconds
            tell application id "\(browser.bundleID)"
              close tab (item 2 of argv as integer) of window id (item 1 of argv as integer)
            end tell
          end timeout
        end run
        """
    }

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
            guard parts.count == 5, let window = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let index = Int(parts[1]) else { return nil }
            let url = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserTab(browser: browser, windowID: window, index: index, title: parts[3], url: url, active: parts[2] == "true")
        }
    }

    /// True when osascript failed because the user has not allowed Apple Events to that app.
    public static func isNotAuthorized(_ message: String) -> Bool {
        message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") || message.localizedCaseInsensitiveContains("not allowed")
    }
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
