import Foundation

/// Only a named request ending in "settings" may list macOS panes.
public struct SettingsQuery: Sendable {
    public let pane: SearchRanking.Query?

    public init(_ text: String) {
        var words = SearchRanking.Query(text).literal.split(separator: " ")
        let leading: Set<String> = ["open", "show", "find", "change", "launch", "go", "to", "the", "please"]
        while let first = words.first, leading.contains(String(first)) { words.removeFirst() }
        while let last = words.last, ["please", "pls"].contains(last) { words.removeLast() }
        if words.last == "settings", words.count > 1, words != ["system", "settings"] {
            pane = SearchRanking.Query(words.dropLast().joined(separator: " "))
        } else { pane = nil }
    }
}
