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
    /// Drops cached data, so the next load reads the Mac again.
    func invalidate()
}

extension ThingSource {
    func invalidate() {}
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
        case .calendar: made = CalendarSource()
        case .reminders: made = RemindersSource()
        case .contacts: made = ContactsSource(compose: { [weak self] address in self?.composeMail?(address) })
        case .tabs: made = TabsSource()
        case .history: made = HistorySource()
        case .mail: made = MailSource(model: self)
        default: made = nil
        }
        sources[kind] = made
        return made
    }

    /// Loads the rows for the source query in the search field. A newer load cancels an older one.
    func loadSource(revision current: UUID, delay: UInt64 = 0) {
        guard let sourceQuery, let source = source(sourceQuery.kind) else { return }
        isLoadingSource = !sourceRows.contains(where: \.isCurrent)
        sourceProblem = nil
        sourceTask?.cancel()
        let filter = sourceQuery.filter
        sourceTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self, self.visible, self.revision == current else { return }
            self.rebuild()
            let outcome: Result<[LauncherResult], Error>
            do { outcome = .success(try await source.load(filter)) } catch { outcome = .failure(error) }
            guard !Task.isCancelled, self.visible, self.revision == current else { return }
            switch outcome {
            case .success(let rows):
                self.sourceRows = rows.map { row in var row = row; row.section = .named(source.section); return row }
                self.sourceProblem = nil
            case .failure(let error):
                self.sourceRows = []
                self.sourceProblem = error as? SourceProblem ?? SourceProblem(text: error.localizedDescription)
            }
            self.isLoadingSource = false
            self.rebuild()
        }
    }

    /// Reloads the list after a verb that keeps the launcher open. The source reads fresh data.
    func reloadSource() {
        guard let sourceQuery else { rebuild(); return }
        source(sourceQuery.kind)?.invalidate()
        loadSource(revision: revision)
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
