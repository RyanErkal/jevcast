import SwiftUI
import LauncherCore

/// Sidebar of sections, and the chosen section beside it.
struct AutomationsRootView: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        NavigationSplitView {
            AutomationsSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .navigationTitle(model.section.title)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search")
        .toolbar { toolbar }
        .frame(minWidth: 860, minHeight: 520)
        .sheet(item: $model.editor) { request in
            AutomationEditorView(model: model, draft: request.draft, dismiss: { model.editor = nil })
        }
        .sheet(isPresented: $model.showQuillExplainer) { QuillExplainerSheet(model: model) }
        .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible, presenting: model.pendingDelete) { automation in
            Button("Move to Trash", role: .destructive) { model.delete(automation.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its settings and run history move to the Trash. You can put them back from the Trash.")
        }
        .overlay(alignment: .bottom) { banner }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .all: AutomationListSplit(model: model)
        case .needsYou, .running, .failed, .history: RunListSplit(model: model, section: model.section)
        case .quill: QuillTasksView(model: model)
        case .codex: CodexSectionView(model: model)
        case .clients: ClientsSectionView(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.runSelected() } label: { Label("Run Now", systemImage: "play.fill") }
                .help("Run the selected automation now (⌘R)")
                .disabled(model.runnableSelection == nil)
            Menu {
                ForEach(AutomationTemplate.allCases.filter { $0 != .blank }) { template in
                    Button { model.newAutomation(template) } label: { Label(template.title, systemImage: template.symbol) }
                }
                Divider()
                Button { model.newAutomation() } label: { Label("Blank Automation", systemImage: "square.dashed") }
            } label: {
                Label("New Automation", systemImage: "plus")
            } primaryAction: {
                model.newAutomation()
            }
            .help("New automation (⌘N). Hold for templates.")
        }
    }

    private var deleteTitle: String { "Delete “\(model.pendingDelete?.name ?? "")”?" }
    private var deleteShown: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }

    @ViewBuilder private var banner: some View {
        if let text = model.banner {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                Text(text).font(.callout)
                Button { model.banner = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.bottom, 16)
            .task(id: text) { try? await Task.sleep(nanoseconds: 6_000_000_000); if model.banner == text { model.banner = nil } }
        }
    }
}

/// Explains that a morning brief is a Quill task, with a button to start one.
struct QuillExplainerSheet: View {
    @ObservedObject var model: AutomationsViewModel
    var body: some View {
        VStack(spacing: 14) {
            SymbolTile(symbol: "sun.horizon", tint: .orange, size: 52)
            Text("Morning brief is a Quill task").font(.title2.weight(.semibold))
            Text("Quill tasks read your Calendar, Reminders, and unread Mail inside Jevcast and write a short brief at the time you choose. Type what you want in the launcher, such as “every weekday at 8am brief me on my meetings and unread email”.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            HStack {
                Button("Cancel") { model.showQuillExplainer = false }.keyboardShortcut(.cancelAction)
                Button("New Quill Task") { model.newQuillTask() }.keyboardShortcut(.defaultAction)
                    .disabled(model.onNewQuillTask == nil && !model.isDemo)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 480)
    }
}
