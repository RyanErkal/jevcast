import Foundation
import SwiftUI
import LauncherCore

/// Offline mail settings intended to be embedded in the launcher's existing Settings or reader
/// panel. It owns no window and does not open a composer or a separate mail surface.
struct MailOfflineSettingsView: View {
    @ObservedObject var center: NativeMailCenter

    init(center: NativeMailCenter) { self.center = center }

    var body: some View {
        Form {
            Section {
                Text("Choose what Jevcast keeps on this Mac. Recent mail preserves the current bounded behavior. Folder history and bodies continue in small background steps.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(center.accounts) { account in
                MailOfflineAccountPolicyRow(center: center, account: account)
            }
            if center.accounts.isEmpty {
                Text("Add a Jevcast mail account to choose offline storage.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await center.refreshOfflineState() }
    }
}

private struct MailOfflineAccountPolicyRow: View {
    @ObservedObject var center: NativeMailCenter
    let account: NativeMailAccount
    @State private var policy = MailOfflinePolicy.default
    @State private var loaded = false
    @State private var saving = false
    @State private var saveError: String?

    private var coverage: [MailOfflineMailboxCoverage] {
        (center.offlineCoverage[account.id] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Keep a configured folder visible when a previous sync has not listed it yet. Known names
    /// come from the actual local mailbox catalogue, not a free-form comma-separated setting.
    private var folderNames: [String] {
        let known = Set(coverage.map(\.name))
        return Array(known.union(policy.selectedFolderNames)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        Section(account.email) {
            Picker("History", selection: $policy.mode) {
                ForEach(MailOfflineDownloadMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if policy.mode == .recent {
                Stepper("Recent messages: \(policy.recentMessageLimit)", value: $policy.recentMessageLimit, in: 0...100_000, step: 50)
            }
            if policy.mode == .selectedFolders {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Folders to keep offline").font(.headline)
                    if folderNames.isEmpty {
                        Text("Folders appear here after Jevcast lists this account.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(folderNames, id: \.self) { name in
                            Toggle(isOn: folderBinding(name)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                    if let item = coverage.first(where: { $0.name == name }) {
                                        Text(coverageSummary(item))
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Not listed on this Mac yet")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Toggle("Index message bodies", isOn: $policy.indexBodies)
            Toggle("Keep attachment bytes for offline reading", isOn: $policy.downloadAttachments)
            Toggle("Pause background offline work", isOn: $policy.paused)
            VStack(alignment: .leading, spacing: 8) {
                Text("Offline coverage").font(.headline)
                if coverage.isEmpty {
                    Text("No local folder coverage yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(coverage) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text(item.coverage.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unknown")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(coverageSummary(item)).font(.caption).foregroundStyle(.secondary)
                            if let error = item.lastError, !error.isEmpty {
                                Text("Last error: \(error)")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                if let report = center.offlineStorageReports[account.id] {
                    Text("Stored \(report.cachedMessageBodies) full message bodies, \(ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let queue = center.offlineQueueStatus[account.id], queue.total > 0 {
                Text("Queued changes: \(queue.pending) waiting, \(queue.review) need review, \(queue.failed) failed")
                    .font(.caption).foregroundStyle(queue.review > 0 ? .orange : .secondary)
                if let error = queue.lastError, !error.isEmpty {
                    Text("Last queue error: \(error)")
                        .font(.caption).foregroundStyle(.red)
                }
                ForEach(center.offlineQueuedActions[account.id, default: []].filter { $0.state == .review }) { action in
                    HStack(alignment: .firstTextBaseline) {
                        Text(action.lastError ?? action.state.title).font(.caption)
                        Spacer()
                        Button("Retry after review") { Task { await center.retryOfflineAction(action.id) } }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Retry failed changes") { Task { await center.retryOfflineQueue(accountID: account.id) } }
                    .disabled(queue.failed == 0)
            }
            HStack {
                Button("Clear cached bodies") {
                    Task {
                        do {
                            try await center.clearOfflineCache(accountID: account.id)
                            saveError = nil
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                }
                if saving { ProgressView().controlSize(.small) }
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
        }
        .task(id: account.id) {
            loaded = false
            saveError = nil
            let stored = await center.offlinePolicy(for: account.id)
            guard !Task.isCancelled else { return }
            if let stored { policy = stored }
            loaded = true
        }
        .onChange(of: policy) { _, value in
            guard loaded else { return }
            saving = true
            saveError = nil
            Task {
                do {
                    try await center.setOfflinePolicy(value, for: account.id)
                    await MainActor.run { saving = false }
                } catch {
                    await MainActor.run {
                        saving = false
                        saveError = error.localizedDescription
                    }
                }
            }
        }
        .onDisappear { loaded = false }
    }

    private func folderBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { policy.selectedFolderNames.contains(name) },
            set: { selected in
                if selected { policy.selectedFolderNames.insert(name) }
                else { policy.selectedFolderNames.remove(name) }
            }
        )
    }

    private func coverageSummary(_ item: MailOfflineMailboxCoverage) -> String {
        let headers = item.serverTotal.map { "\(item.downloadedHeaders) of \($0) headers" }
            ?? "\(item.downloadedHeaders) headers cached"
        let history = item.completeHistory ? "history complete" : "history incomplete"
        let bodies = "\(item.indexedBodies) of \(item.bodyCandidates) bodies indexed"
        return "\(headers), \(bodies), \(history)"
    }
}
