import Foundation
import LauncherCore

extension MailModel {
    var canSearchServer: Bool {
        NativeMailCenter.activeEngine != nil && place != .outbox && (!search.isEmpty || [.unread, .flagged].contains(place))
    }

    func resetServerSearch() {
        serverSearchWork?.cancel(); serverSearchWork = nil
        serverSearchCursors = [:]; serverSearchValidities = [:]; serverSearchRows = []
        serverSearch = .available
    }

    /// An explicit search reads bounded server ranges and saves matching headers only.
    func searchServer() {
        guard canSearchServer, serverSearch != .running, serverSearch != .complete,
              let engine = NativeMailCenter.activeEngine, let root else { return }
        let query = Self.query(queryPlace, search, mailboxes), generation = generation
        let cursors = serverSearchCursors, validities = serverSearchValidities
        serverSearch = .running
        serverSearchWork = Task { @MainActor [weak self] in
            do {
                let result = try await engine.search(mailboxIDs: query.mailboxes, text: query.text,
                                                     unreadOnly: query.unreadOnly, flaggedOnly: query.flaggedOnly,
                                                     cursors: cursors, validities: validities)
                try Task.checkCancellation()
                var matches = query
                matches.text = ""; matches.rowIDs = result.rowIDs; matches.limit = 200
                let rows = result.rowIDs.isEmpty ? [] : try await Task.detached(priority: .userInitiated) {
                    try MailStore.messages(root: root, matches)
                }.value
                guard let self, self.generation == generation, self.root == root,
                      NativeMailCenter.activeEngine === engine else { return }
                self.serverSearchCursors = result.cursors; self.serverSearchValidities = result.validities
                self.serverSearchRows = Self.merge(self.serverSearchRows, rows, query: query)
                if result.complete { self.serverSearch = .complete }
                else if query.mailboxes.allSatisfy({ result.cursors[$0] == 0 }) {
                    self.serverSearch = .limited("This server limits search history. These results may be incomplete.")
                } else { self.serverSearch = .more }
                self.install(Self.merge(self.messages, rows, query: query))
            } catch is CancellationError { return }
            catch {
                guard let self, self.generation == generation else { return }
                self.serverSearch = .failed(error.localizedDescription)
            }
        }
    }

    func updateServerHistory() {
        guard search.isEmpty, NativeMailCenter.activeEngine != nil, place != .outbox else { olderOnServer = false; return }
        let ids = Set(Self.query(queryPlace, search, mailboxes).mailboxes)
        olderOnServer = mailboxes.contains { ids.contains($0.rowID) && $0.syncComplete != true }
    }
}
