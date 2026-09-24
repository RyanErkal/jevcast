import AppKit
import LauncherCore

extension Diagnostics {
    /// `--diagnose-source 'scheduled tasks'`: prints the rows a source query lists, with each row's verbs.
    /// Runs nothing. Output stays in the terminal.
    static func source(_ text: String) {
        guard let query = SourceQuery.parse(text) else { print("Not a source query: \(text)"); exit(1) }
        let catalogue = AppCatalogue()
        catalogue.refresh(extra: [])
        let model = LauncherModel(preferences: Preferences(), catalogue: catalogue)
        Task { @MainActor in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                guard let source = model.source(query.kind) else { print("No source for \(query.kind.rawValue) yet."); exit(1) }
                let rows = try await source.load(query.filter)
                print("\(source.section): \(rows.count) rows in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms")
                for row in rows {
                    print("• \(row.title)\n  \(row.detail)")
                    if case .thing(let thing) = row.action { print("  verbs: " + thing.verbs.map(\.title).joined(separator: ", ")) }
                }
            } catch {
                print("Problem: \(error.localizedDescription)")
            }
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.run()
    }
}
