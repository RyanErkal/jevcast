import AppKit
import LauncherCore

/// `--snapshot-ui <dir> --demo` renders with invented files, Apple apps only,
/// and fresh settings, so screenshots for the website carry no personal data.
@MainActor
enum DemoData {
    static var isEnabled: Bool { CommandLine.arguments.contains("--demo") }
    /// Apple's own apps, so an app query never lists what this Mac has installed.
    static let appRoots = ["/System/Applications", "/Applications/Safari.app", "/System/Library/CoreServices/Finder.app"]
    /// A folder laid out like a home folder. File rows show it as "~".
    static let home = NSTemporaryDirectory() + "JevLauncherDemo"
    /// Types that Apple's own apps open, so rows never show another vendor's document icon.
    private static let files = [
        "Downloads/Brand guidelines 2026.key", "Downloads/Quarterly report Q3.numbers", "Downloads/Invoice 1042.pages",
        "Downloads/Studio floor plan.png", "Downloads/Team offsite agenda.pages", "Downloads/Product demo.mov",
        "Documents/Invoices/Invoice 1041.pages", "Documents/Invoices/Invoice 1040.pages", "Documents/Contracts/Studio lease.pages",
        "Documents/Launch plan.key", "Documents/Photos/Safari trip.heic", "Documents/Projects/Safety checklist.numbers",
        "Desktop/Moodboard.png"
    ]

    /// Writes the empty sample files once, so rows show real type icons.
    static func makeFileSearch() -> DemoFileSearch {
        let fm = FileManager.default
        try? fm.removeItem(atPath: home)
        let entries = files.map { relative -> FileEntry in
            let path = home + "/" + relative
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data())
            return FileEntry(path: path, name: (relative as NSString).lastPathComponent, modifiedDate: Date())
        }
        return DemoFileSearch(entries: entries)
    }

    static let clipboard = [
        "https://github.com/RyanErkal/jevcast", "Meeting moved to Thursday at 10:00\nRoom 4B", "£1,240.00"
    ]
}

/// File search over the sample files, with the same name, kind, and folder filters as the real search.
@MainActor
final class DemoFileSearch: FileSearching {
    var onStatus: ((String) -> Void)?
    private let entries: [FileEntry]
    init(entries: [FileEntry]) { self.entries = entries }
    func stop() {}
    func search(_ text: String, folders: [String], completion: @escaping ([FileEntry]) -> Void) {
        let query = FileSearchQuery.parse(text)
        let folder = query.scope.map { "/" + $0.rawValue.capitalized + "/" }
        let found = entries.filter { entry in
            query.matches(name: entry.name, path: entry.path, isDirectory: entry.isDirectory, modifiedDate: entry.modifiedDate)
                && folder.map(entry.path.contains) != false
        }
        onStatus?(found.isEmpty ? "No matching files" : "")
        completion(found)
    }
}
