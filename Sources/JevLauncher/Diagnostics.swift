import Foundation
import LauncherCore

@MainActor
enum Diagnostics {
    private struct Report: Encodable {
        let appCount: Int
        let discoveryMilliseconds: Double
        let searchP50Milliseconds: Double
        let searchP95Milliseconds: Double
        let windowActionCount: Int
        let cases: [[String: String]]
        let note: String
    }
    static func searchFiles(_ query: String) {
        let search = FileSearch()
        let start = ProcessInfo.processInfo.systemUptime
        search.onStatus = { print($0); fflush(stdout) }
        search.search(query, folders: Preferences().fileFolders) { results in
            print("File results: \(results.count), elapsed: \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)) ms")
            for file in results { print(file.name) }
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { search.stop(); exit(0) }
        withExtendedLifetime(search) { RunLoop.main.run() }
    }
    static func run() {
        let start = CFAbsoluteTimeGetCurrent()
        let apps = AppCatalogue.scan(roots: ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", "/System/Library/CoreServices/Finder.app", NSHomeDirectory() + "/Applications"])
        let discovery = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let phrases = ["Safari", "open safari", "left half", "move this to the right half", "top left", "middle third", "tile all", "next monitor", "full screen", "terminal"]
        var timings: [Double] = []
        var outcomes: [[String: String]] = []
        for round in 0..<20 {
            for phrase in phrases {
                let begin = CFAbsoluteTimeGetCurrent()
                var candidates: [(String, Double)] = apps.compactMap { app in
                    guard let score = SearchRanking.score(query: phrase, title: app.name) else { return nil }
                    return (app.name, score)
                }
                candidates += WindowAction.allCases.compactMap { action in
                    guard let score = SearchRanking.score(query: phrase, title: action.title, aliases: action.aliases) else { return nil }
                    return (action.title, score)
                }
                candidates.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
                timings.append((CFAbsoluteTimeGetCurrent() - begin) * 1000)
                if round == 0 { outcomes.append(["query": phrase, "first": candidates.first?.0 ?? "none"]) }
            }
        }
        timings.sort()
        let result = Report(
            appCount: apps.count,
            discoveryMilliseconds: discovery,
            searchP50Milliseconds: timings[timings.count / 2],
            searchP95Milliseconds: timings[Int(Double(timings.count - 1) * 0.95)],
            windowActionCount: WindowAction.allCases.count,
            cases: outcomes,
            note: "Read-only catalogue/ranking diagnostic. Does not measure panel rendering, microphone, Jev, or window execution."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
