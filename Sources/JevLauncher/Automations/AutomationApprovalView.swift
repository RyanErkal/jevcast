import AppKit
import SwiftUI
import LauncherCore

/// Changes an agent proposed. Items are grouped by operation; refused items show why and cannot be picked.
struct ApprovalView: View {
    @ObservedObject var model: AutomationsViewModel
    let run: RunRecord
    @State private var manifest: Result<ProposalManifest, ProposalError>?
    @State private var loaded = false
    @State private var chosen: Set<String> = []
    @State private var focused: String?
    @State private var journal: ApplyJournal?
    @State private var undoResult: ApplyJournal?
    @State private var revising = false
    @State private var note = ""
    @State private var preview = FilePreview()

    var body: some View {
        VStack(spacing: 0) {
            RunHeader(model: model, run: run).padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            content
        }
        .task(id: run.id) {
            manifest = model.proposal(for: run)
            journal = model.journal(for: run)
            if case .success(let m) = manifest { chosen = Set(m.checked.map(\.id)) }
            loaded = true
        }
        .onDisappear { preview.close() }
        .sheet(isPresented: $revising) { reviseSheet }
    }

    @ViewBuilder private var content: some View {
        if let journal {
            ApplyResultView(journal: journal, undoResult: undoResult) { undoResult = model.undo(run) }
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch manifest {
            case .success(let m): proposal(m)
            case .failure(let error):
                EmptyStateView(symbol: "exclamationmark.octagon", title: "These changes were refused",
                               message: "Jevcast checked the agent's proposal and could not accept it: \(Self.describe(error)). Nothing was changed.",
                               actionTitle: "Reject") { model.reject(run) }
            case nil:
                EmptyStateView(symbol: "questionmark.folder", title: "No proposal found",
                               message: "The run's proposal file is missing.", actionTitle: "Open Run Folder") { model.reveal(run) }
            }
        }
    }

    private func proposal(_ m: ProposalManifest) -> some View {
        let checked = Dictionary(uniqueKeysWithValues: m.checked.map { ($0.id, $0) })
        let groups = ProposalItem.Operation.allCases.compactMap { op -> (ProposalItem.Operation, [ProposalItem])? in
            let items = m.proposal.items.filter { $0.op == op }
            return items.isEmpty ? nil : (op, items)
        }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.proposal.summary).font(.title3.weight(.medium)).textSelection(.enabled)
                Text("\(m.checked.count) of \(m.proposal.items.count) changes can be applied. Inside: " + m.roots.map(Paths.display).joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            List(selection: $focused) {
                ForEach(groups, id: \.0) { op, items in
                    Section(op.title) {
                        ForEach(items) { item in
                            ProposalRow(item: item, checked: checked[item.id], refusal: m.refused[item.id],
                                        isOn: Binding(get: { chosen.contains(item.id) },
                                                      set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }),
                                        preview: { showPreview(checked[item.id]) })
                                .tag(item.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(.space) {
                guard let focused, let item = checked[focused] else { return .ignored }
                showPreview(item); return .handled
            }
            Divider()
            footer(m)
        }
    }

    private func footer(_ m: ProposalManifest) -> some View {
        HStack {
            Button("Reject All", role: .destructive) { model.reject(run) }
            Button("Ask for Changes…") { revising = true }
            Spacer()
            Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected").font(.callout).foregroundStyle(.secondary)
            Button("Approve \(chosen.count) Change\(chosen.count == 1 ? "" : "s")") { journal = model.approve(run, items: chosen) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    private var reviseSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask for changes").font(.headline)
            Text("The agent makes a new proposal with your note. You approve it again.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $note).font(.body).frame(width: 400, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel") { revising = false }.keyboardShortcut(.cancelAction)
                Button("Send") { model.revise(run, note: note); revising = false; note = "" }
                    .keyboardShortcut(.defaultAction).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    /// Quick Look for a file that exists now. The check runs on the click, not while drawing.
    private func showPreview(_ item: CheckedItem?) {
        guard let item, item.item.op != .mkdir, FileManager.default.fileExists(atPath: item.source),
              let window = NSApp.keyWindow else { return }
        preview.toggle(path: item.source, beside: window)
    }

    static func describe(_ error: ProposalError) -> String {
        switch error {
        case .tooLarge(let n): return "it is too large (\(n) bytes)"
        case .invalidJSON(let s): return "it is not valid (\(s))"
        case .unsupportedVersion(let v): return "it uses an unsupported version (\(v))"
        case .tooManyItems(let n): return "it has too many items (\(n))"
        case .duplicateItemID(let id): return "item \(id) appears twice"
        case .invalidItemID(let id): return "item ID \(id) is not valid"
        case .unknownOperation(let op): return "“\(op)” is not an allowed change"
        case .unexpectedField(let f): return "it has an unexpected field “\(f)”"
        case .noRoots: return "the automation has no allowed folders"
        }
    }
}

struct ProposalRow: View {
    let item: ProposalItem
    let checked: CheckedItem?
    let refusal: String?
    @Binding var isOn: Bool
    let preview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if refusal == nil {
                Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("Approve " + URL(fileURLWithPath: source).lastPathComponent)
            } else {
                Image(systemName: "nosign").foregroundStyle(.secondary).frame(width: 16).accessibilityLabel("Refused")
            }
            FileIconView(path: source, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: source).lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                pathLine
                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                if let refusal { Label(refusal, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 4)
            if checked != nil, item.op != .mkdir {
                Button(action: preview) { Image(systemName: "eye") }.buttonStyle(.borderless)
                    .help("Quick Look (Space)").accessibilityLabel("Quick Look")
            }
        }
        .padding(.vertical, 4)
        .opacity(refusal == nil ? 1 : 0.55)
    }

    private var source: String { checked?.source ?? item.from ?? item.path ?? "" }
    private var destination: String? {
        if let d = checked?.destination, item.op != .mkdir { return d }
        if item.op == .rename, let name = item.name { return name }
        if item.op == .tag { return item.tags?.joined(separator: ", ") }
        return item.op == .mkdir ? nil : item.to
    }

    @ViewBuilder private var pathLine: some View {
        HStack(spacing: 5) {
            Text(Paths.display((source as NSString).deletingLastPathComponent))
            if let destination {
                Image(systemName: "arrow.right").font(.caption2)
                Text(item.op == .tag ? "Tags: " + destination : Paths.display(destination))
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }
}

/// What approving did, item by item, with Undo.
struct ApplyResultView: View {
    let journal: ApplyJournal
    let undoResult: ApplyJournal?
    let undo: () -> Void

    var body: some View {
        let shown = undoResult ?? journal
        let done = shown.entries.filter { $0.status == .done }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(undoResult == nil ? "Applied \(done) of \(shown.entries.count) changes" : "Undo finished").font(.title3.weight(.semibold))
                    Text("Items that changed on disk after the proposal were skipped.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if undoResult == nil { Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.controlSize(.large) }
            }
            List(shown.entries, id: \.itemID) { entry in
                HStack(spacing: 8) {
                    Image(systemName: symbol(entry.status)).foregroundStyle(tint(entry.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.op.title + " " + URL(fileURLWithPath: entry.source).lastPathComponent).lineLimit(1)
                        if let message = entry.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(entry.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
    }

    private func symbol(_ s: ApplyJournal.Entry.Status) -> String {
        switch s { case .done, .undone: return "checkmark.circle.fill"; case .failed, .undoBlocked: return "xmark.circle.fill"; case .skipped: return "minus.circle"; case .intended: return "questionmark.circle" }
    }
    private func tint(_ s: ApplyJournal.Entry.Status) -> Color {
        switch s { case .done, .undone: return .green; case .failed, .undoBlocked: return .red; case .skipped, .intended: return .secondary }
    }
}
