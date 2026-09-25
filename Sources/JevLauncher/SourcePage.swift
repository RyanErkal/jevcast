import AppKit
import SwiftUI
import LauncherCore

/// A panel view over a source's rows: Calendar, Tasks, Clipboard, and Clean Up. Rows and verbs
/// come from the same sources the search uses. Return opens a row's detail, or runs its first verb
/// when the view has no detail; ⇧Return runs its second verb.
@MainActor
final class SourcePage: ObservableObject, LauncherPage {
    let id: ViewID
    private let source: ThingSource?
    /// Words passed to the source, such as "week" for the calendar.
    private let scope: String
    /// Sources that filter themselves get the typed text; others are filtered here.
    private let filtersInSource: Bool
    private let hasDetail: Bool
    /// Extra content for a row's detail, such as a task result's text.
    private let detailBody: (LauncherResult) -> AnyView?
    private let popOutAction: (() -> Void)?
    private let emptyText: String
    private weak var model: LauncherModel?

    @Published private(set) var rows: [LauncherResult] = []
    @Published private(set) var loading = false
    @Published private(set) var problem: SourceProblem?
    @Published private(set) var note: String?
    @Published var selectedID: String?
    @Published private(set) var detailID: String?
    private var all: [LauncherResult] = []
    private var text = ""
    private var work: Task<Void, Never>?
    private var confirmID: String?

    init(_ id: ViewID, source: ThingSource?, model: LauncherModel, scope: String = "", filtersInSource: Bool = false, hasDetail: Bool,
         emptyText: String, popOut: (() -> Void)? = nil, detailBody: @escaping (LauncherResult) -> AnyView? = { _ in nil }) {
        self.id = id; self.source = source; self.model = model; self.scope = scope; self.filtersInSource = filtersInSource
        self.hasDetail = hasDetail; self.emptyText = emptyText; self.popOutAction = popOut; self.detailBody = detailBody
    }

    var selected: LauncherResult? { rows.first { $0.id == selectedID } }
    var detail: LauncherResult? {
        guard let detailID else { return nil }
        return rows.first { $0.id == detailID } ?? all.first { $0.id == detailID }
    }
    var canPopOut: Bool { popOutAction != nil }
    func popOut() { popOutAction?() }
    func opened() { reload() }
    func closed(handingOff: Bool) { work?.cancel() }

    func reload() {
        guard let source else { all = []; applyFilter(); return }
        work?.cancel()
        loading = rows.isEmpty
        let filter = filtersInSource ? text : scope
        work = Task { @MainActor [weak self] in
            do {
                let loaded = try await source.load(filter)
                guard !Task.isCancelled, let self else { return }
                self.all = loaded; self.problem = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.all = []; self.problem = error as? SourceProblem ?? SourceProblem(text: error.localizedDescription)
            }
            self?.loading = false
            self?.applyFilter()
        }
    }

    func filter(_ text: String) {
        self.text = text
        detailID = nil
        if filtersInSource { reload() } else { applyFilter() }
    }

    private func applyFilter() {
        let words = text.trimmingCharacters(in: .whitespaces)
        rows = filtersInSource || words.isEmpty ? all
            : all.filter { SearchRanking.score(query: words, title: $0.title, aliases: [$0.detail]) != nil }
        if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
        if detailID != nil, detail == nil { detailID = nil }
    }

    func handle(_ key: PageKey) -> Bool {
        switch key {
        case .up, .down:
            guard detailID == nil, !rows.isEmpty else { return true }
            let index = rows.firstIndex { $0.id == selectedID } ?? 0
            selectedID = rows[min(max(index + (key == .down ? 1 : -1), 0), rows.count - 1)].id
            note = nil; confirmID = nil
        case .open(let shift):
            // Rows wait for a reload after a verb, so an old row never runs twice.
            if let detail { if detail.isCurrent, let verb = verbs(detail).first { run(verb) }; return true }
            guard let row = selected, row.isCurrent else { return true }
            let verbs = verbs(row)
            if shift, verbs.count > 1 {
                // Clean Up's second verb stops a process, so it asks for a second ⇧Return.
                if id == .cleanup && confirmID != row.id { confirmID = row.id; note = "Press ⇧Return again to " + verbs[1].title.lowercased() + "."; return true }
                confirmID = nil
                run(verbs[1])
            }
            else if hasDetail { detailID = row.id }
            else if let verb = verbs.first { run(verb) }
        case .delete, .left, .right: return false
        }
        return true
    }

    func back() -> Bool {
        guard detailID != nil else { return false }
        detailID = nil
        return true
    }

    /// Opens a row's detail directly, such as a task result from a notification.
    func showDetail(_ rowID: String) { detailID = rowID; selectedID = rowID }

    func verbs(_ row: LauncherResult) -> [Verb] {
        if case .thing(let thing) = row.action { return thing.verbs }
        return []
    }

    /// Runs a verb as the search rows do: closing verbs close the panel, others stay and reload.
    func run(_ verb: Verb) {
        switch verb.after {
        case .close, .closeKeepFocus:
            model?.onClose?(verb.after == .close)
            Task { @MainActor [weak model] in
                do { _ = try await verb.run() } catch { model?.showFailure(error.localizedDescription) }
            }
        case .stay, .keepOpen:
            if verb.after == .stay {
                all = all.map { var row = $0; row.isCurrent = false; return row }
                rows = rows.map { var row = $0; row.isCurrent = false; return row }
            }
            Task { @MainActor [weak self] in
                do { self?.note = try await verb.run() } catch { self?.note = error.localizedDescription }
                if verb.after == .stay { self?.source?.invalidate(); self?.reload() }
            }
        }
    }

    func grant() {
        guard let access = problem?.access else { return }
        Task { @MainActor [weak self] in await Permissions.request(access); self?.reload() }
    }

    func content() -> AnyView {
        AnyView(SourcePageView(page: self, emptyText: emptyText, detailBody: detailBody))
    }
}

private struct SourcePageView: View {
    @ObservedObject var page: SourcePage
    let emptyText: String
    let detailBody: (LauncherResult) -> AnyView?

    var body: some View {
        VStack(spacing: 0) {
            if let detail = page.detail { detailView(detail) } else { list }
            if let note = page.note {
                Divider()
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, LauncherMetrics.gutter).padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var list: some View {
        if page.rows.isEmpty {
            VStack(spacing: 10) {
                if page.loading { ProgressView().controlSize(.small) }
                else {
                    Text(page.problem?.text ?? emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    if page.problem?.access != nil { Button("Allow Access") { page.grant() } }
                }
            }
            .font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: LauncherMetrics.rowSpacing) {
                        ForEach(page.rows) { row in rowView(row).id(row.id) }
                    }
                    .padding(.horizontal, LauncherMetrics.listInset).padding(.vertical, LauncherMetrics.listPadding)
                }
                .onChange(of: page.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    private func rowView(_ row: LauncherResult) -> some View {
        let selected = row.id == page.selectedID
        return HStack(spacing: LauncherMetrics.iconSpacing) {
            Image(systemName: row.symbol).font(.system(size: LauncherMetrics.symbolPointSize))
                .foregroundStyle(.secondary).frame(width: LauncherMetrics.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: LauncherMetrics.titleSize)).lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail).font(.system(size: LauncherMetrics.subtitleSize)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // The selected row shows its other verbs, such as Stop Now and Always Ignore.
            if selected {
                ForEach(Array(page.verbs(row).dropFirst().enumerated()), id: \.offset) { _, verb in
                    Button(verb.title) { page.run(verb) }.controlSize(.small).disabled(!row.isCurrent)
                }
            }
        }
        .padding(.horizontal, LauncherMetrics.cellInset)
        .frame(height: LauncherMetrics.tallCellHeight)
        .background(RoundedRectangle(cornerRadius: LauncherMetrics.highlightRadius).fill(selected ? Color.primary.opacity(0.09) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { page.selectedID = row.id; _ = page.handle(.open(shift: false)) }
        .onTapGesture { page.selectedID = row.id }
    }

    private func detailView(_ row: LauncherResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: LauncherMetrics.iconSpacing) {
                Image(systemName: row.symbol).font(.system(size: 20)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(row.detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            HStack {
                ForEach(Array(page.verbs(row).enumerated()), id: \.offset) { index, verb in
                    Button(verb.title) { page.run(verb) }.controlSize(.small).disabled(!row.isCurrent)
                        .buttonStyle(.bordered).tint(index == 0 ? .accentColor : nil)
                }
            }
            if let body = detailBody(row) { body } else { Spacer() }
        }
        .padding(LauncherMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
