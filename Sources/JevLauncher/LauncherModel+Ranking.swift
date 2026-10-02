import LauncherCore

extension LauncherModel {
    /// Confidence uses the lexical match, never a favourite or usage boost.
    var hasClearLocalAnswer: Bool {
        guard let top = results.first(where: \.isCurrent) else { return false }
        if top.score >= Self.bareKeywordScore { return true }
        guard let score = top.localMatchScore else { return false }
        if score == Self.exactScore { return true }
        guard score >= 90 else { return false }
        let next = results.filter { $0.isCurrent && $0.id != top.id }.compactMap(\.localMatchScore).max() ?? 0
        return score - next >= 10
    }

    /// Every path, including memory and cache, obeys hidden-app and pane scope.
    func isEligibleCandidate(_ id: String) -> Bool {
        let appID = id.hasPrefix("open:") ? String(id.dropFirst(5).split(separator: "|", maxSplits: 1).first ?? "") : id
        guard !preferences.hiddenApps.contains(appID) else { return false }
        guard let app = catalogue.entries.first(where: { $0.id == appID }), app.launchURL != nil else { return true }
        return appSearchIndex.score(app, query: SearchRanking.Query(query), settings: SettingsQuery(query),
                                    aliases: aliasesByApp[app.id] ?? []) != nil
    }

    func canPromote(_ id: String) -> Bool {
        guard visible, page == nil, !manualSelection, !isComposingSearch, canResolve(id) else { return false }
        return !hasClearLocalAnswer || results.first(where: \.isCurrent)?.id == id
    }
}
