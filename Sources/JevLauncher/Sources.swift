import AppKit
import LauncherCore

/// A source of things on the Mac, such as scheduled jobs or calendar events.
/// `load` runs when the query names the source, and again after a verb that stays open.
@MainActor
protocol ThingSource: AnyObject {
    /// The group label above the rows, such as "Scheduled Tasks".
    var section: String { get }
    /// Rows that match `filter`, best first. Throws `SourceProblem` when access is missing.
    func load(_ filter: String) async throws -> [LauncherResult]
}

/// Why a source shows nothing, with the button that fixes it.
struct SourceProblem: LocalizedError {
    let text: String
    var access: SourceAccess?
    var errorDescription: String? { text }
}

extension LauncherModel {
    /// The source for a query kind, made once per launcher.
    func source(_ kind: SourceQuery.Kind) -> ThingSource? {
        if let existing = sources[kind] { return existing }
        let made: ThingSource?
        switch kind {
        case .scheduled: made = ScheduledSource(timers: timers, catalogue: catalogue)
        default: made = nil
        }
        sources[kind] = made
        return made
    }

    /// Loads the rows for the source query in the search field.
    func loadSource(revision current: UUID) {
        guard let sourceQuery, let source = source(sourceQuery.kind) else { return }
        isLoadingSource = sourceRows.isEmpty
        sourceProblem = nil
        rebuild()
        let filter = sourceQuery.filter
        Task { @MainActor [weak self] in
            do {
                let rows = try await source.load(filter)
                guard let self, self.visible, self.revision == current else { return }
                self.sourceRows = rows.map { row in var row = row; row.section = .named(source.section); return row }
                self.sourceProblem = nil
            } catch {
                guard let self, self.visible, self.revision == current else { return }
                self.sourceRows = []
                self.sourceProblem = error as? SourceProblem ?? SourceProblem(text: error.localizedDescription)
            }
            self?.isLoadingSource = false
            self?.rebuild()
        }
    }

    /// Reloads the list after a verb that keeps the launcher open.
    func reloadSource() {
        if sourceQuery != nil { loadSource(revision: revision) } else { rebuild() }
    }

    /// The strip text for a source: a permission problem, a verb's result, or why the list is empty.
    var sourceNotice: Notice? {
        guard sourceQuery != nil else { return nil }
        if let sourceProblem {
            return Notice(symbol: "lock", text: sourceProblem.text, tone: .info, action: sourceProblem.access.map { .grant($0) })
        }
        if let sourceNote { return Notice(symbol: "checkmark.circle", text: sourceNote, tone: .info) }
        if isLoadingSource { return Notice(symbol: "hourglass", text: "Loading…", tone: .info) }
        return nil
    }

    /// Asks for the permission a source needs, then loads it again.
    func grant(_ access: SourceAccess) {
        Task { @MainActor [weak self] in
            await Permissions.request(access)
            self?.reloadSource()
        }
    }
}
