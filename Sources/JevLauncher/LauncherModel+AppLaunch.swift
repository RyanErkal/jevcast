import Foundation

extension LauncherModel {
    func launchApplication(_ app: AppEntry, result: LauncherResult) {
        let token = UUID(), session = visibleSession, searchRevision = revision
        applicationLaunchToken = token; launchingAppID = app.id
        let input = query
        let learnsIntent = shouldLearnFromExecution(result)
        applicationLauncher.open(app) { [weak self] outcome in
            guard let self else { return }
            let ownsLaunch = self.applicationLaunchToken == token
            if ownsLaunch { self.applicationLaunchToken = nil; self.launchingAppID = nil }
            switch outcome {
            case .failure(let error):
                if ownsLaunch, self.visibleSession == session, self.revision == searchRevision { self.showFailure(error.localizedDescription) }
            case .success:
                if learnsIntent { self.preferences.learn(input, id: result.id) }
                if result.learnsFromUse && Self.prefix(for: input) == nil { self.preferences.record(result.id, query: input) }
                if ownsLaunch, self.visibleSession == session, self.revision == searchRevision { self.onClose?(false) }
            }
        }
    }
}
