import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// The imported mailbox lives in the launcher panel. It never creates a mail or compose window.
/// The root mounts it with `MailArchiveView(store: store)` from its toolbar/page content.
struct MailArchiveView: View {
    @StateObject private var model: MailArchiveViewModel

    init(store: MailArchiveStore) {
        _model = StateObject(wrappedValue: MailArchiveViewModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                list
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
                Divider()
                reader
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if model.showsPreview, let preview = model.pendingPreview {
                ZStack {
                    Color.black.opacity(0.22).ignoresSafeArea()
                    MailArchivePreviewPanel(preview: preview, importAction: model.importPending, cancelAction: model.dismissPreview)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 18)
                        .padding(24)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.showsPreview)
        .alert("Mail archive", isPresented: $model.showsNotice) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Imported Mail").font(.headline)
            Text("Local only").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { model.importFile() } label: { Label("Import", systemImage: "square.and.arrow.down") }
            if let progress = model.progress, progress.stage != .finished {
                ProgressView(value: Double(progress.bytesProcessed), total: Double(max(1, progress.totalBytes)))
                    .frame(width: 90).help("Reading or saving mail archive")
            }
            Menu {
                Button("Selected as .eml…") { model.exportSelected(format: .eml) }
                    .disabled(model.selected == nil)
                Button("Selected as .mbox…") { model.exportSelected(format: .mbox) }
                    .disabled(model.selected == nil)
                Divider()
                Button("All as .mbox…") { model.exportAll() }.disabled(model.messages.isEmpty)
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search imported mail", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            if model.messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(model.query.isEmpty ? "No imported mail" : "No matching mail").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.messages, selection: $model.selectedID) { message in
                    MailArchiveRow(message: message)
                        .tag(message.id)
                        .contextMenu {
                            Button("Export as .eml…") { model.export(message: message, format: .eml) }
                            Button("Export as .mbox…") { model.export(message: message, format: .mbox) }
                        }
                }
                .listStyle(.plain)
            }
        }
    }

    private var reader: some View {
        Group {
            if let record = model.selected, let detail = model.detail {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.subject.isEmpty ? "No subject" : record.subject)
                            .font(.title3.weight(.semibold)).textSelection(.enabled)
                        if !record.sender.isEmpty { Text(record.sender).font(.system(size: 12)).textSelection(.enabled) }
                        if !record.recipients.isEmpty { Text("To: " + record.recipients).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if let date = record.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        if !detail.attachments.isEmpty { attachmentBar(record: record, detail: detail) }
                    }
                    .padding(14)
                    Divider()
                    if let html = detail.html, !html.isEmpty {
                        MailHTMLView(html: html, documentID: Int64(record.id.hashValue), inlineImages: detail.inlineImages,
                                     loadsRemote: false, fitsWidth: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView([.vertical, .horizontal]) {
                            Text(detail.readableText)
                                .font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "envelope.open").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Select imported mail").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func attachmentBar(record: MailArchiveMessage, detail: MIMEMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            ForEach(Array(detail.attachments.enumerated()), id: \.offset) { index, attachment in
                Button {
                    model.saveAttachment(record: record, detail: detail, index: index)
                } label: {
                    Text("\(attachment.name) (\(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)))")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .help("Save attachment")
            }
        }
        .font(.caption)
    }
}

private struct MailArchiveRow: View {
    let message: MailArchiveMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(message.sender.isEmpty ? "Unknown sender" : message.sender)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let date = message.date { Text(Self.date(date)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(message.subject.isEmpty ? "No subject" : message.subject)
                .font(.system(size: 12)).lineLimit(1)
            if !message.attachments.isEmpty {
                Label("\(message.attachments.count)", systemImage: "paperclip").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private static func date(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct MailArchivePreviewPanel: View {
    let preview: MailArchivePreview
    let importAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review import").font(.title3.weight(.semibold))
            Text("\(preview.messages.count) valid message\(preview.messages.count == 1 ? "" : "s"), \(preview.duplicateCount) duplicate\(preview.duplicateCount == 1 ? "" : "s"), \(preview.errors.count) issue\(preview.errors.count == 1 ? "" : "s").")
                .foregroundStyle(.secondary)
            List {
                ForEach(preview.messages) { message in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.subject.isEmpty ? "No subject" : message.subject).lineLimit(1)
                            Text(message.sender).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if message.duplicate { Text("Duplicate").font(.caption).foregroundStyle(.orange) }
                    }
                }
                if !preview.errors.isEmpty {
                    Section("Issues") {
                        ForEach(preview.errors) { issue in
                            Label(issue.detail, systemImage: issue.kind == .duplicate ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(issue.kind == .duplicate ? .orange : .secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancelAction).keyboardShortcut(.cancelAction)
                Button("Import valid mail", action: importAction)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(preview.messages.allSatisfy(\.duplicate))
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 420)
    }
}

@MainActor
private final class MailArchiveViewModel: ObservableObject {
    let store: MailArchiveStore
    @Published var query = "" { didSet { reload() } }
    @Published var messages: [MailArchiveMessage] = []
    @Published var selectedID: UUID? { didSet { loadDetail() } }
    @Published private(set) var detail: MIMEMessage?
    @Published var pendingPreview: MailArchivePreview?
    @Published var showsPreview = false
    @Published var notice: String?
    @Published var progress: MailArchiveProgress?

    private var pendingURL: URL?
    var showsNotice: Bool {
        get { notice != nil }
        set { if !newValue { notice = nil } }
    }

    init(store: MailArchiveStore) {
        self.store = store
        reload()
    }

    var selected: MailArchiveMessage? { messages.first { $0.id == selectedID } ?? store.allMessages().first { $0.id == selectedID } }

    func reload() {
        messages = store.messages(matching: query).sorted { ($0.date ?? $0.importedAt) > ($1.date ?? $1.importedAt) }
        if let selectedID, !messages.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        loadDetail()
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eml")!, UTType(filenameExtension: "mbox")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingURL = url
            pendingPreview = try store.preview(url: url) { [weak self] value in self?.progress = value }
            showsPreview = true
        } catch { notice = error.localizedDescription }
    }

    func dismissPreview() {
        pendingURL = nil; pendingPreview = nil; showsPreview = false
    }

    func importPending() {
        guard let url = pendingURL, let preview = pendingPreview else { return }
        do {
            let result = try store.importArchive(url: url, preview: preview) { [weak self] value in self?.progress = value }
            let issueText = result.errors.isEmpty ? "" : " \(result.errors.count) issue\(result.errors.count == 1 ? "" : "s") was skipped."
            notice = "Imported \(result.imported.count) message\(result.imported.count == 1 ? "" : "s").\(issueText)"
            dismissPreview(); reload()
        } catch { notice = error.localizedDescription; dismissPreview() }
    }

    func exportSelected(format: MailArchiveFormat) {
        guard let selected else { return }
        export(message: selected, format: format)
    }

    func exportAll() {
        presentSave(format: .mbox) { [weak self] url in
            guard let self else { throw MailArchiveError.storageFailure }
            return try self.store.export(format: .mbox, to: url, overwrite: true)
        }
    }

    func export(message: MailArchiveMessage, format: MailArchiveFormat) {
        presentSave(format: format) { [weak self] url in
            guard let self else { throw MailArchiveError.storageFailure }
            return try self.store.export(ids: [message.id], format: format, to: url, overwrite: true)
        }
    }

    func saveAttachment(record: MailArchiveMessage, detail: MIMEMessage, index: Int) {
        do {
            let files = try MailReceivedAttachmentExtractor.extract(rawMessage: store.rawMessage(for: record.id), expected: detail)
            guard files.indices.contains(index) else { return }
            let attachment = files[index]
            let panel = NSSavePanel(); panel.canCreateDirectories = false
            panel.nameFieldStringValue = MailArchiveStore.safeFilename(attachment.name, fallback: "attachment")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // NSSavePanel has already handled the user's replacement confirmation.
            try store.saveAttachmentData(attachment.data, to: url, overwrite: true)
        } catch { notice = error.localizedDescription }
    }

    private func presentSave(format: MailArchiveFormat, action: @escaping (URL) throws -> MailArchiveExportResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .eml ? UTType(filenameExtension: "eml")! : UTType(filenameExtension: "mbox")!]
        panel.canCreateDirectories = false
        panel.nameFieldStringValue = format == .eml ? "Mail Archive.eml" : "Mail Archive.mbox"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try action(url); notice = "Exported mail." } catch { notice = error.localizedDescription }
    }

    private func loadDetail() {
        guard let selectedID else { detail = nil; return }
        do { detail = try MIMEMessage.parse(store.rawMessage(for: selectedID)) }
        catch { detail = nil; notice = error.localizedDescription }
    }

}
