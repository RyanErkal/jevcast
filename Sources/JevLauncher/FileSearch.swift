import Foundation
import LauncherCore

public struct FileEntry: Identifiable, Sendable, Equatable {
    public let path: String
    public let name: String
    public let modifiedDate: Date?
    public let isDirectory: Bool

    public var id: String { "file:" + path }

    public init(path: String, name: String, modifiedDate: Date? = nil, isDirectory: Bool = false) {
        self.path = path
        self.name = name
        self.modifiedDate = modifiedDate
        self.isDirectory = isDirectory
    }
}

/// Bounded local file search backed by Spotlight's metadata index.
///
/// The parser and all filters live in LauncherCore. This type only resolves
/// configured scopes and turns metadata results into launchable entries.
@MainActor
protocol FileSearching: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
    func stop()
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void)
}

@MainActor
public final class FileSearch: FileSearching {
    public var onStatus: ((String) -> Void)?

    private var query: NSMetadataQuery?
    private var generation = UUID()
    private var tokens: [NSObjectProtocol] = []

    private let maxScan = 640
    private let maxResults = 40
    private var lastPublished: [FileEntry]?

    public init() {}

    public func stop() {
        generation = UUID()
        lastPublished = nil
        query?.stop()
        query = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    public func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) {
        stop()
        let parsed = FileSearchQuery.parse(text)

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status("Type a file name or filter.")
            completion([])
            return
        }
        guard parsed.isValid else {
            status(parsed.filterSummary)
            completion([])
            return
        }

        guard parsed.isExplicitFileSearch || parsed.nameQuery.count >= 2 else {
            status(""); completion([]); return
        }
        let configuredScopes = normalizedScopes(folders)
        guard !configuredScopes.isEmpty else {
            status("Add a search folder in Settings.")
            completion([])
            return
        }

        if let explicitPath = parsed.explicitPath {
            let path = URL(fileURLWithPath: expandedPath(explicitPath)).standardizedFileURL.resolvingSymlinksInPath().path
            guard isInsideConfiguredScope(path, scopes: configuredScopes) else {
                status("That path is outside your configured search folders.")
                completion([])
                return
            }
            let result = directEntry(path: path, query: parsed)
            if result.isEmpty {
                status("Path not found · \(path)")
            } else {
                status("1 result · \(parsed.filterSummary)")
            }
            completion(result)
            return
        }

        let scopes = effectiveScopes(for: parsed, configured: configuredScopes)
        guard !scopes.isEmpty else {
            status("That folder is not in your configured search folders.")
            completion([])
            return
        }

        status("Searching · \(parsed.filterSummary)")
        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = scopes.map(\.path)
        metadataQuery.predicate = predicate(for: parsed)
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        metadataQuery.notificationBatchingInterval = 0.08
        query = metadataQuery
        let currentGeneration = generation

        let publish = { [weak self, weak metadataQuery] in
            guard let self, let metadataQuery, self.generation == currentGeneration, self.query === metadataQuery else { return }
            metadataQuery.disableUpdates()
            let results = self.entries(from: metadataQuery, query: parsed, scopes: scopes)
            metadataQuery.enableUpdates()
            if results.isEmpty {
                self.status(metadataQuery.isGathering ? "Searching · " + parsed.filterSummary : "No indexed matches. Check search folders and Spotlight indexing.")
            } else {
                let limit = metadataQuery.resultCount > self.maxScan ? " · Recent matches; narrow your search" : ""
                self.status("\(results.count) result\(results.count == 1 ? "" : "s") · \(parsed.filterSummary)" + limit)
            }
            if self.lastPublished != results {
                self.lastPublished = results
                completion(results)
            }
        }

        for name in [NSNotification.Name.NSMetadataQueryGatheringProgress, NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: metadataQuery, queue: .main) { _ in
                Task { @MainActor in publish() }
            })
        }

        guard metadataQuery.start() else {
            stop()
            status("File search could not start.")
            completion([])
            return
        }
    }

    private func status(_ value: String) {
        onStatus?(value)
    }

    func predicate(for query: FileSearchQuery, now: Date = Date(), calendar: Calendar = .current) -> NSPredicate {
        var predicates = query.nameQuery.split(separator: " ").map {
            NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, String($0))
        }
        if let kind = query.kind {
            let extensions = kind.fileExtensions
            if kind == .folder {
                predicates.append(NSPredicate(format: "%K == %@", "kMDItemContentType", "public.folder"))
            } else {
                let types = extensions.map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*." + $0) }
                predicates.append(types.count == 1 ? types[0] : NSCompoundPredicate(orPredicateWithSubpredicates: types))
            }
        }
        if let interval = query.modifiedInterval(now: now, calendar: calendar) {
            predicates.append(NSPredicate(format: "%K >= %@", NSMetadataItemFSContentChangeDateKey, interval.start as NSDate))
            predicates.append(NSPredicate(format: "%K < %@", NSMetadataItemFSContentChangeDateKey, interval.end as NSDate))
        }
        // Spotlight rejects AND/OR predicates containing only one child.
        if predicates.isEmpty { return NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*") }
        return predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private func entries(
        from metadataQuery: NSMetadataQuery,
        query: FileSearchQuery,
        scopes: [URL]
    ) -> [FileEntry] {
        let count = min(metadataQuery.resultCount, maxScan)
        var candidates: [(entry: FileEntry, relevance: Double)] = []
        candidates.reserveCapacity(min(count, maxResults * 4))

        for index in 0..<count {
            guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                  let rawPath = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard !isNoise(path), isInsideAnyScope(path, scopes: scopes) else { continue }

            let url = URL(fileURLWithPath: path)
            let isDirectory = (item.value(forAttribute: "kMDItemContentType") as? String) == "public.folder"
            let modifiedDate = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent
            guard query.matches(
                name: name,
                path: path,
                isDirectory: isDirectory,
                modifiedDate: modifiedDate
            ) else { continue }

            let entry = FileEntry(path: path, name: name, modifiedDate: modifiedDate, isDirectory: isDirectory)
            candidates.append((entry, relevance(of: entry, query: query)))
        }

        candidates.sort {
            if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
            let leftDate = $0.entry.modifiedDate ?? .distantPast
            let rightDate = $1.entry.modifiedDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending
        }
        return candidates.prefix(maxResults).map(\.entry)
    }

    private func directEntry(path: String, query: FileSearchQuery) -> [FileEntry] {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !Self.isNoise(url.path) else { return [] }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
        let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        let modifiedDate = values?.contentModificationDate
        let name = url.lastPathComponent
        guard query.matches(name: name, path: url.path, isDirectory: isDirectory, modifiedDate: modifiedDate) else { return [] }
        return [FileEntry(path: url.path, name: name, modifiedDate: modifiedDate, isDirectory: isDirectory)]
    }

    private func relevance(of entry: FileEntry, query: FileSearchQuery) -> Double {
        guard !query.nameQuery.isEmpty else { return 0 }
        let foldedName = FileSearchQuery.fold(entry.name)
        let foldedQuery = FileSearchQuery.fold(query.nameQuery)
        if foldedName == foldedQuery { return 1.0 }
        if foldedName.hasPrefix(foldedQuery) { return 0.95 }
        let words = foldedQuery.split(separator: " ").map(String.init)
        let matched = words.filter { foldedName.contains($0) }.count
        guard !words.isEmpty else { return 0 }
        return 0.65 * Double(matched) / Double(words.count)
    }

    private func normalizedScopes(_ folders: [String]) -> [URL] {
        var seen = Set<String>()
        return folders.compactMap { folder in
            let path = expandedPath(folder)
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    func effectiveScopes(for query: FileSearchQuery, configured: [URL]) -> [URL] {
        guard let requested = requestedScope(for: query) else { return configured }
        var result: [URL] = []
        for root in configured {
            if isInside(requested.path, root.path) {
                // The requested scope is narrower than a configured root.
                result.append(requested)
            } else if isInside(root.path, requested.path) {
                // A configured root is narrower than the requested scope.
                result.append(root)
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }

    private func requestedScope(for query: FileSearchQuery) -> URL? {
        if let scopePath = query.scopePath {
            return URL(fileURLWithPath: expandedPath(scopePath)).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard let scope = query.scope else { return nil }
        let folder: String
        switch scope {
        case .downloads: folder = "Downloads"
        case .desktop: folder = "Desktop"
        case .documents: folder = "Documents"
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(folder).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func expandedPath(_ value: String) -> String {
        if value.lowercased().hasPrefix("file://"), let url = URL(string: value) { return url.path }
        if value == "~" { return NSHomeDirectory() }
        if value.hasPrefix("~/") { return NSHomeDirectory() + String(value.dropFirst(1)) }
        return value
    }

    private func isInsideConfiguredScope(_ path: String, scopes: [URL]) -> Bool {
        isInsideAnyScope(path, scopes: scopes)
    }

    private func isInsideAnyScope(_ path: String, scopes: [URL]) -> Bool {
        scopes.contains { isInside(path, $0.path) }
    }

    private func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func isNoise(_ path: String) -> Bool {
        Self.isNoise(path)
    }

    private static func isNoise(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if components.contains(where: { component in
            component == ".git" || component == "node_modules" || component == ".Trash" || component.hasSuffix(".app")
        }) { return true }
        return path.contains("/Library/Caches/")
    }
}
