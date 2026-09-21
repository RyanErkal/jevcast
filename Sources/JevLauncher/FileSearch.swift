import Foundation

struct FileEntry: Identifiable {
    let path: String
    let name: String
    var id: String { "file:" + path }
}

@MainActor
final class FileSearch {
    private var query: NSMetadataQuery?
    private var generation = UUID()
    private var tokens: [NSObjectProtocol] = []
    func stop() {
        generation = UUID()
        query?.stop(); query = nil
        tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
    }
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) {
        stop()
        guard text.count >= 2, !folders.isEmpty else { completion([]); return }
        let query = NSMetadataQuery()
        query.searchScopes = folders
        let words = text.split(separator: " ").map(String.init)
        let predicates = words.prefix(8).map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.12
        self.query = query
        let generation = self.generation
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == generation, let query = self.query else { return }
                    query.disableUpdates()
                    var results: [FileEntry] = []
                    for item in query.results.prefix(80) {
                        guard let item = item as? NSMetadataItem,
                              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                              !path.contains(".app/"), !path.hasSuffix(".app") else { continue }
                        let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? URL(fileURLWithPath: path).lastPathComponent
                        results.append(FileEntry(path: path, name: name))
                        if results.count == 16 { break }
                    }
                    query.enableUpdates()
                    completion(results)
                }
            })
        }
        if !query.start() { completion([]) }
    }
}
