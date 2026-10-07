import SwiftUI

/// Why the open draft is not being saved to the server Drafts folder. A refused sign-in offers one
/// explicit retry; every other block says how to continue without changing the server copy.
struct MailServerDraftStatusRow: View {
    @ObservedObject var coordinator: MailServerDraftCoordinator
    let draft: MailModel.Draft
    let reason: String

    var body: some View {
        let retrying = coordinator.retryingDraftIDs.contains(draft.id)
        let canRetry = coordinator.canRetryServerSave(draft)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(retrying ? "Signing in and saving to the server Drafts folder…" : reason,
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(note(canRetry: canRetry || retrying)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if canRetry || retrying {
                Button("Save to Drafts Again") { Task { await coordinator.retryServerSave(draft) } }
                    .controlSize(.small).disabled(retrying)
                    .help("Signs in once with the account's current details and saves this draft to its server Drafts folder. It does not send.")
            }
        }
        .font(.caption).padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func note(canRetry: Bool) -> String {
        if canRetry { return "Autosave to the server stays off until you choose Save to Drafts Again. This does not send." }
        if coordinator.blockAllowsRetry(draft) {
            return "Select Jevcast accounts as the mail source to save this draft to the server again."
        }
        return "Jevcast will not change this server draft again. Check the server Drafts folder, then discard this draft or copy its text into a new message."
    }
}
