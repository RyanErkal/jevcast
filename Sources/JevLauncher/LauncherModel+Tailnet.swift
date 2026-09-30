import AppKit
import LauncherCore

extension LauncherModel {
    /// Pages the Tailnet view listed last, for a search such as "qbit". Read from preferences, so typing
    /// asks the tailnet nothing. Jev never sees them: the rows carry no Jev description.
    func tailnetPageRows(_ q: String) -> [LauncherResult] {
        preferences.tailnetPages.compactMap { page in
            guard let score = SearchRanking.score(query: q, title: page.title, aliases: [page.label]) else { return nil }
            let open = Verb(title: "Open", after: .closeKeepFocus) { Frontmost.open(page.url); return nil }
            // An app with the same name stays first.
            return LauncherResult(id: "tailnet:search:" + page.id, title: page.title, detail: page.label + " · Tailnet page", symbol: "globe",
                                  action: .thing(Thing(verbs: [open, TailnetActions.copy("Copy URL", page.url.absoluteString)], twoLine: false)),
                                  score: score * 100 - 3)
        }
    }
}
