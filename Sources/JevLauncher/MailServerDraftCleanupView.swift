import SwiftUI

struct MailServerDraftCleanupView: View {
    @ObservedObject var model: MailModel
    @ObservedObject var coordinator: MailServerDraftCoordinator
    @State private var selected: MailServerDraftCleanupRecord?
    @State private var removing = false

    init(model: MailModel) {
        self.model = model
        coordinator = model.serverDrafts
    }

    var body: some View {
        Group {
            if !coordinator.pendingCleanupRecords.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server drafts need attention").font(.callout.weight(.medium))
                    ForEach(coordinator.pendingCleanupRecords) { record in
                        HStack(alignment: .top) {
                            Text(record.reason).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove Drafts Copy…") { selected = record }
                                .controlSize(.small).disabled(removing)
                        }
                    }
                }.padding(10).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear { coordinator.reloadCleanup() }
        .confirmationDialog("Remove saved server draft copies?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let record = selected {
                Button("Remove \(record.references.count) Drafts \(record.references.count == 1 ? "Copy" : "Copies")", role: .destructive) {
                    selected = nil; removing = true
                    Task { _ = await coordinator.retryServerDraftCleanup(record); removing = false }
                }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text("Jevcast checks each saved draft before removal. This does not send a message.")
        }
    }
}
