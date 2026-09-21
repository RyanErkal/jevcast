import XCTest
@testable import LauncherCore

/// A bounded corpus for the local command matcher. These are deliberately
/// ordinary phrases a person may type or say, rather than synthetic token
/// permutations. The candidate list mirrors the launcher: controlled app
/// names plus every current built-in window action and its aliases.
final class CommandAcceptanceTests: XCTestCase {
    private struct Candidate {
        let id: String
        let title: String
        let aliases: [String]
    }

    private struct Request {
        let phrase: String
        let expectedID: String?
    }

    func testTypedAndSpokenCommandCorpus() {
        let candidates = appCandidates + WindowAction.allCases.map {
            Candidate(id: "window:" + $0.rawValue, title: $0.title, aliases: $0.aliases)
        }

        let requests: [Request] = [
            // Halves.
            Request(phrase: "left half", expectedID: "window:left-half"),
            Request(phrase: "open left half", expectedID: "window:left-half"),
            Request(phrase: "move this to the left half", expectedID: "window:left-half"),
            Request(phrase: "left side", expectedID: "window:left-half"),
            Request(phrase: "snap window left", expectedID: "window:left-half"),
            Request(phrase: "position right half", expectedID: "window:right-half"),
            Request(phrase: "right side", expectedID: "window:right-half"),
            Request(phrase: "open right", expectedID: "window:right-half"),
            Request(phrase: "top half", expectedID: "window:top-half"),
            Request(phrase: "put window top", expectedID: "window:top-half"),
            Request(phrase: "bottom half", expectedID: "window:bottom-half"),
            Request(phrase: "move window bottom", expectedID: "window:bottom-half"),
            Request(phrase: "switch to left side", expectedID: "window:left-half"),
            Request(phrase: "launch right half", expectedID: "window:right-half"),

            // Quarters.
            Request(phrase: "top left quarter", expectedID: "window:top-left-quarter"),
            Request(phrase: "upper left", expectedID: "window:top-left-quarter"),
            Request(phrase: "move this to upper left", expectedID: "window:top-left-quarter"),
            Request(phrase: "top right quarter", expectedID: "window:top-right-quarter"),
            Request(phrase: "upper right", expectedID: "window:top-right-quarter"),
            Request(phrase: "move to upper right", expectedID: "window:top-right-quarter"),
            Request(phrase: "bottom left quarter", expectedID: "window:bottom-left-quarter"),
            Request(phrase: "lower left", expectedID: "window:bottom-left-quarter"),
            Request(phrase: "put in lower left", expectedID: "window:bottom-left-quarter"),
            Request(phrase: "bottom right quarter", expectedID: "window:bottom-right-quarter"),
            Request(phrase: "lower right", expectedID: "window:bottom-right-quarter"),
            Request(phrase: "arrange bottom right", expectedID: "window:bottom-right-quarter"),
            Request(phrase: "switch top-left-quarter", expectedID: "window:top-left-quarter"),
            Request(phrase: "launch bottom-right", expectedID: "window:bottom-right-quarter"),
            Request(phrase: "move to top right quarter", expectedID: "window:top-right-quarter"),

            // Thirds.
            Request(phrase: "left third", expectedID: "window:left-third"),
            Request(phrase: "left 1/3", expectedID: "window:left-third"),
            Request(phrase: "one third left", expectedID: "window:left-third"),
            Request(phrase: "move left third", expectedID: "window:left-third"),
            Request(phrase: "center third", expectedID: "window:center-third"),
            Request(phrase: "middle third", expectedID: "window:center-third"),
            Request(phrase: "center 1/3", expectedID: "window:center-third"),
            Request(phrase: "open center third", expectedID: "window:center-third"),
            Request(phrase: "right third", expectedID: "window:right-third"),
            Request(phrase: "one third right", expectedID: "window:right-third"),
            Request(phrase: "right 1/3", expectedID: "window:right-third"),
            Request(phrase: "move right third", expectedID: "window:right-third"),
            Request(phrase: "left two thirds", expectedID: "window:left-two-thirds"),
            Request(phrase: "left 2/3", expectedID: "window:left-two-thirds"),
            Request(phrase: "open left two thirds", expectedID: "window:left-two-thirds"),
            Request(phrase: "right two thirds", expectedID: "window:right-two-thirds"),
            Request(phrase: "right 2/3", expectedID: "window:right-two-thirds"),

            // Sixths.
            Request(phrase: "top left sixth", expectedID: "window:top-left-sixth"),
            Request(phrase: "top left 1/6", expectedID: "window:top-left-sixth"),
            Request(phrase: "move top left sixth", expectedID: "window:top-left-sixth"),
            Request(phrase: "top center sixth", expectedID: "window:top-center-sixth"),
            Request(phrase: "top center 1/6", expectedID: "window:top-center-sixth"),
            Request(phrase: "move top center sixth", expectedID: "window:top-center-sixth"),
            Request(phrase: "top right sixth", expectedID: "window:top-right-sixth"),
            Request(phrase: "top right 1/6", expectedID: "window:top-right-sixth"),
            Request(phrase: "move top right sixth", expectedID: "window:top-right-sixth"),
            Request(phrase: "bottom left sixth", expectedID: "window:bottom-left-sixth"),
            Request(phrase: "bottom left 1/6", expectedID: "window:bottom-left-sixth"),
            Request(phrase: "move bottom left sixth", expectedID: "window:bottom-left-sixth"),
            Request(phrase: "bottom center sixth", expectedID: "window:bottom-center-sixth"),
            Request(phrase: "bottom center 1/6", expectedID: "window:bottom-center-sixth"),
            Request(phrase: "move bottom center sixth", expectedID: "window:bottom-center-sixth"),
            Request(phrase: "bottom right sixth", expectedID: "window:bottom-right-sixth"),
            Request(phrase: "bottom right 1/6", expectedID: "window:bottom-right-sixth"),
            Request(phrase: "move bottom right sixth", expectedID: "window:bottom-right-sixth"),

            // Window commands, monitor movement, and bulk layout.
            Request(phrase: "fullscreen", expectedID: "window:fullscreen"),
            Request(phrase: "full screen", expectedID: "window:fullscreen"),
            Request(phrase: "open fullscreen", expectedID: "window:fullscreen"),
            Request(phrase: "maximize", expectedID: "window:maximize"),
            Request(phrase: "max", expectedID: "window:maximize"),
            Request(phrase: "fill", expectedID: "window:maximize"),
            Request(phrase: "maximize this window", expectedID: "window:maximize"),
            Request(phrase: "center", expectedID: "window:center"),
            Request(phrase: "centre", expectedID: "window:center"),
            Request(phrase: "middle", expectedID: "window:center"),
            Request(phrase: "center the window", expectedID: "window:center"),
            Request(phrase: "larger", expectedID: "window:larger"),
            Request(phrase: "grow", expectedID: "window:larger"),
            Request(phrase: "increase window", expectedID: "window:larger"),
            Request(phrase: "larger window", expectedID: "window:larger"),
            Request(phrase: "smaller", expectedID: "window:smaller"),
            Request(phrase: "shrink", expectedID: "window:smaller"),
            Request(phrase: "decrease window", expectedID: "window:smaller"),
            Request(phrase: "smaller window", expectedID: "window:smaller"),
            Request(phrase: "restore", expectedID: "window:restore"),
            Request(phrase: "undo", expectedID: "window:restore"),
            Request(phrase: "reset window", expectedID: "window:restore"),
            Request(phrase: "restore this window", expectedID: "window:restore"),
            Request(phrase: "next display", expectedID: "window:next-display"),
            Request(phrase: "next monitor", expectedID: "window:next-display"),
            Request(phrase: "next screen", expectedID: "window:next-display"),
            Request(phrase: "switch to next monitor", expectedID: "window:next-display"),
            Request(phrase: "previous display", expectedID: "window:previous-display"),
            Request(phrase: "previous monitor", expectedID: "window:previous-display"),
            Request(phrase: "previous screen", expectedID: "window:previous-display"),
            Request(phrase: "switch previous screen", expectedID: "window:previous-display"),
            Request(phrase: "tile all", expectedID: "window:tile-all"),
            Request(phrase: "tile windows", expectedID: "window:tile-all"),
            Request(phrase: "cascade all", expectedID: "window:cascade-all"),
            Request(phrase: "cascade windows", expectedID: "window:cascade-all"),

            // Controlled app names and user-facing aliases.
            Request(phrase: "Safari", expectedID: "app:safari"),
            Request(phrase: "open Safari", expectedID: "app:safari"),
            Request(phrase: "launch Safari browser", expectedID: "app:safari"),
            Request(phrase: "Apple browser", expectedID: "app:safari"),
            Request(phrase: "Google Chrome", expectedID: "app:chrome"),
            Request(phrase: "open Chrome", expectedID: "app:chrome"),
            Request(phrase: "launch Chrome browser", expectedID: "app:chrome"),
            Request(phrase: "Visual Studio Code", expectedID: "app:code"),
            Request(phrase: "launch code", expectedID: "app:code"),
            Request(phrase: "VSCode", expectedID: "app:code"),
            Request(phrase: "open editor", expectedID: "app:code"),
            Request(phrase: "Slack", expectedID: "app:slack"),
            Request(phrase: "open Slack", expectedID: "app:slack"),
            Request(phrase: "team chat", expectedID: "app:slack"),
            Request(phrase: "Calendar", expectedID: "app:calendar"),
            Request(phrase: "show calendar", expectedID: "app:calendar"),
            Request(phrase: "schedule", expectedID: "app:calendar"),
            Request(phrase: "Terminal", expectedID: "app:terminal"),
            Request(phrase: "open terminal shell", expectedID: "app:terminal"),
            Request(phrase: "command line", expectedID: "app:terminal"),
            Request(phrase: "Notes", expectedID: "app:notes"),
            Request(phrase: "quick note", expectedID: "app:notes"),
            Request(phrase: "Finder", expectedID: "app:finder"),
            Request(phrase: "file manager", expectedID: "app:finder"),
            Request(phrase: "Mail", expectedID: "app:mail"),
            Request(phrase: "email", expectedID: "app:mail"),
            Request(phrase: "inbox", expectedID: "app:mail"),
            Request(phrase: "Music", expectedID: "app:music"),
            Request(phrase: "iTunes", expectedID: "app:music"),
            Request(phrase: "audio", expectedID: "app:music"),

            // These have no controlled candidate and should remain unmatched.
            Request(phrase: "quantum banana", expectedID: nil),
            Request(phrase: "zzzz desktop action", expectedID: nil),
            Request(phrase: "launch Photoshop", expectedID: nil)
        ]

        XCTAssertGreaterThanOrEqual(requests.count, 100)
        XCTAssertEqual(requests.count, 132)

        for request in requests {
            let ranked = candidates.compactMap { candidate -> (Candidate, Double)? in
                guard let score = SearchRanking.score(
                    query: request.phrase,
                    title: candidate.title,
                    aliases: candidate.aliases
                ) else { return nil }
                return (candidate, score)
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.id < $1.0.id
            }

            if let expectedID = request.expectedID {
                XCTAssertEqual(
                    ranked.first?.0.id,
                    expectedID,
                    "Expected \(expectedID) to rank first for \(request.phrase). Ranked: \(ranked.map { ($0.0.id, $0.1) })"
                )
            } else {
                XCTAssertTrue(
                    ranked.isEmpty,
                    "Expected no match for \(request.phrase), got \(ranked.map { ($0.0.id, $0.1) })"
                )
            }
        }
    }

    private var appCandidates: [Candidate] {
        [
            Candidate(id: "app:safari", title: "Safari", aliases: ["apple browser", "web browser", "safari browser"]),
            Candidate(id: "app:chrome", title: "Google Chrome", aliases: ["chrome", "chrome browser"]),
            Candidate(id: "app:code", title: "Visual Studio Code", aliases: ["code", "vscode", "editor"]),
            Candidate(id: "app:slack", title: "Slack", aliases: ["team chat", "slack chat"]),
            Candidate(id: "app:calendar", title: "Calendar", aliases: ["schedule", "events"]),
            Candidate(id: "app:terminal", title: "Terminal", aliases: ["shell", "command line"]),
            Candidate(id: "app:notes", title: "Notes", aliases: ["notepad", "quick note"]),
            Candidate(id: "app:finder", title: "Finder", aliases: ["files", "file manager"]),
            Candidate(id: "app:mail", title: "Mail", aliases: ["email", "inbox"]),
            Candidate(id: "app:music", title: "Music", aliases: ["itunes", "audio"])
        ]
    }
}
