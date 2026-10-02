import LauncherCore

extension LauncherModel {
    /// Confidence uses the lexical match, never a favourite or usage boost.
    var hasClearLocalAnswer: Bool {
        clearLocalAnswer(in: results) != nil
    }

    private func clearLocalAnswer(in rows: [LauncherResult]) -> LauncherResult? {
        guard let top = rows.filter(\.isCurrent).max(by: { $0.score < $1.score }) else { return nil }
        if top.score >= Self.bareKeywordScore { return top }
        guard let score = top.localMatchScore else { return nil }
        if score == Self.exactScore { return top }
        guard score >= 90 else { return nil }
        let next = rows.filter { $0.isCurrent && $0.id != top.id }.compactMap(\.localMatchScore).max() ?? 0
        return score - next >= 10 ? top : nil
    }

    /// A catalogue or preference update can invalidate a pick already on screen.
    func reconcilePromotedResult(with localRows: [LauncherResult]) {
        guard let promotedID else { return }
        let eligible = isEligibleCandidate(promotedID)
        let conflict = !manualSelection && clearLocalAnswer(in: localRows).map { $0.id != promotedID } == true
        guard !eligible || conflict else { return }
        self.promotedID = nil; semanticResult = nil; jevPick = nil
        aiStatus = conflict ? "Kept local match" : ""
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
        return clearLocalAnswer(in: results).map { $0.id == id } ?? true
    }
}
