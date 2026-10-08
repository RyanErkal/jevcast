import AppKit
import Foundation
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// The source selected when the attachment action began. Keeping this value separate from the
/// view prevents a late result from an older message from being shown for a new selection.
struct MailReceivedAttachmentContext: Equatable, Sendable {
    enum Backend: Equatable, Sendable { case appleMail, jevcast }
    struct IndexIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    let root: String
    let mailbox: MailMailbox
    let message: MailSummary
    let detail: MIMEMessage
    let backend: Backend
    let indexIdentity: IndexIdentity?

    @MainActor
    static func make(model: MailModel, message: MailSummary, detail: MIMEMessage) throws -> MailReceivedAttachmentContext {
        guard let selected = model.selected, selected.rowID == message.rowID, selected.messageKey == message.messageKey else {
            throw MailReceivedAttachmentError.sourceChanged
        }
        guard let mailbox = model.mailbox(message.mailbox) else { throw MailReceivedAttachmentError.sourceChanged }
        guard case .ready(let root) = model.status else { throw MailReceivedAttachmentError.bodyUnavailable }
        guard let indexIdentity = model.mailIndexIdentity else {
            throw MailReceivedAttachmentError.sourceChanged
        }
        let backend: Backend = NativeMailCenter.isNativeRoot(root) ? .jevcast : .appleMail
        return MailReceivedAttachmentContext(root: root, mailbox: mailbox, message: message, detail: detail,
                                             backend: backend,
                                             indexIdentity: .init(device: indexIdentity.device, inode: indexIdentity.inode))
    }
}

/// Reads one selected message only after a user asks to preview, open, or save an attachment.
/// Every filesystem read runs away from the main actor. A missing Jevcast body is fetched from
/// its own engine only in this explicit action path; Apple Mail is never asked to do anything.
enum MailReceivedAttachmentLoader {
    static func load(_ context: MailReceivedAttachmentContext) async throws -> [MailReceivedAttachmentFile] {
        // Captured here, on the caller's executor. The detached task must not read UserDefaults or
        // initialize a main-actor static: a caller blocked on this wait never gets back to the main
        // thread, and the read then waits forever. CI hung in this test until the job's time limit.
        let backend = MailBackend.current
        return try await Task.detached(priority: .userInitiated) {
            try await loadOffMain(context, backend: backend)
        }.value
    }

    private static func loadOffMain(_ context: MailReceivedAttachmentContext, backend: MailBackend) async throws -> [MailReceivedAttachmentFile] {
        let identity = context.indexIdentity ?? MailStore.FileIdentity(path: MailStore.indexPath(context.root)).map {
            MailReceivedAttachmentContext.IndexIdentity(device: $0.device, inode: $0.inode)
        }
        try verifySource(context, expectedIdentity: identity, backend: backend)
        var stored = try readStoredBody(context)
        if stored == nil, context.backend == .jevcast {
            guard backend == .jevcast, NativeMailCenter.isNativeRoot(context.root),
                  let engine = NativeMailCenter.activeEngine else { throw MailReceivedAttachmentError.bodyUnavailable }
            _ = try await engine.fetchBody(context.message.rowID)
            stored = try readStoredBody(context)
        }
        guard let stored else { throw MailReceivedAttachmentError.bodyUnavailable }
        try verifySource(context, expectedIdentity: identity, backend: backend)
        let raw = try unwrapEMLX(stored)
        return try MailReceivedAttachmentExtractor.extract(rawMessage: raw, expected: context.detail)
    }

    private static func verifySource(_ context: MailReceivedAttachmentContext,
                                     expectedIdentity: MailReceivedAttachmentContext.IndexIdentity?,
                                     backend: MailBackend) throws {
        guard FileManager.default.fileExists(atPath: MailStore.indexPath(context.root)) else {
            throw MailReceivedAttachmentError.sourceChanged
        }
        if let expected = context.indexIdentity ?? expectedIdentity {
            guard let current = MailStore.FileIdentity(path: MailStore.indexPath(context.root)),
                  current.device == expected.device, current.inode == expected.inode else {
                throw MailReceivedAttachmentError.sourceChanged
            }
        }
        switch context.backend {
        case .appleMail:
            guard backend == .appleMail, !NativeMailCenter.isNativeRoot(context.root) else {
                throw MailReceivedAttachmentError.sourceChanged
            }
        case .jevcast:
            guard backend == .jevcast, NativeMailCenter.isNativeRoot(context.root) else {
                throw MailReceivedAttachmentError.sourceChanged
            }
        }
        guard let current = (try? MailStore.messages(root: context.root, .init(mailboxes: [], rowIDs: [context.message.rowID])))?.first,
              current.rowID == context.message.rowID,
              current.messageKey == context.message.messageKey,
              current.mailbox == context.mailbox.rowID,
              let box = (try? MailStore.mailboxes(root: context.root))?.first(where: { $0.rowID == context.mailbox.rowID }),
              box.url == context.mailbox.url,
              box.accountID == context.mailbox.accountID else {
            throw MailReceivedAttachmentError.sourceChanged
        }
    }

    private static func readStoredBody(_ context: MailReceivedAttachmentContext) throws -> Data? {
        guard let path = MailStore.messageFile(root: context.root, mailbox: context.mailbox, rowID: context.message.rowID) else { return nil }
        let folder = context.mailbox.folder(in: context.root)
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let parent = URL(fileURLWithPath: folder).standardizedFileURL.path
        guard standardized.hasPrefix(parent + "/") else { throw MailReceivedAttachmentError.sourceChanged }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= 100 * 1024 * 1024 else { throw MailReceivedAttachmentError.bodyUnavailable }
        return try handle.read(upToCount: 100 * 1024 * 1024 + 1) ?? Data()
    }

    private static func unwrapEMLX(_ file: Data) throws -> Data {
        guard let newline = file.firstIndex(of: 0x0A) else { return file }
        let first = String(decoding: file[file.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let count = Int(first) else { return file }
        guard count >= 0 else { throw MailReceivedAttachmentError.malformedMessage }
        let start = file.index(after: newline)
        guard count <= file.distance(from: start, to: file.endIndex) else { throw MailReceivedAttachmentError.bodyUnavailable }
        return Data(file[start..<file.index(start, offsetBy: count)])
    }
}

@MainActor
private final class MailReceivedAttachmentsController: ObservableObject {
    enum State: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var items: [MailReceivedAttachmentStaging.Item] = []
    @Published var preview: MailReceivedAttachmentStaging.Item?
    private var context: MailReceivedAttachmentContext?
    private var staging: MailReceivedAttachmentStaging?
    private var request = UUID()

    deinit { staging?.cleanup() }

    func perform(_ operation: Operation, model: MailModel, message: MailSummary, detail: MIMEMessage, index: Int) {
        let context: MailReceivedAttachmentContext
        do { context = try MailReceivedAttachmentContext.make(model: model, message: message, detail: detail) }
        catch { state = .failed(error.localizedDescription); return }
        if self.context == context {
            if case .loading = state { return }
            if case .ready = state, !items.isEmpty {
                finish(operation, index: index)
                return
            }
        }
        let token = UUID(); request = token
        self.context = context
        items = []
        staging?.cleanup(); staging = nil
        state = .loading
        Task { [weak self] in
            do {
                let files = try await MailReceivedAttachmentLoader.load(context)
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let staging = try MailReceivedAttachmentStaging()
                    return (staging, try staging.stage(files))
                }.value
                guard let self, self.request == token else { prepared.0.cleanup(); return }
                self.staging = prepared.0; self.items = prepared.1; self.state = .ready
                self.finish(operation, index: index)
            } catch {
                guard let self, self.request == token else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cleanup() {
        request = UUID(); preview = nil; items = []; context = nil; state = .idle
        staging?.cleanup(); staging = nil
    }

    enum Operation { case preview, open, save }

    private func finish(_ operation: Operation, index: Int) {
        guard items.indices.contains(index) else { state = .failed("This attachment is no longer available."); return }
        let item = items[index]
        switch operation {
        case .preview:
            preview = item
        case .open:
            guard NSWorkspace.shared.open(item.url) else {
                state = .failed("The attachment could not be opened.")
                return
            }
        case .save:
            save(item)
        }
    }

    private func save(_ item: MailReceivedAttachmentStaging.Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.prompt = "Save"
        panel.canCreateDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    let alert = NSAlert()
                    alert.messageText = "Replace existing file?"
                    alert.informativeText = url.lastPathComponent
                    alert.addButton(withTitle: "Replace")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                do {
                    try await Task.detached(priority: .userInitiated) { try Self.copy(item.url, to: url) }.value
                } catch { self.state = .failed("The attachment could not be saved.") }
            }
        }
    }

    private nonisolated static func copy(_ source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let fd = open(destination.path, flags | (exists ? O_TRUNC : O_EXCL), 0o600)
        guard fd >= 0 else { throw MailReceivedAttachmentError.stagingFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        } catch {
            try? handle.close(); throw error
        }
    }
}

/// Received attachments in a message. Rendering reads only the already-loaded MIME metadata.
/// Source bytes are loaded after the user chooses Preview, Open, or Save.
struct MailReceivedAttachments: View {
    @ObservedObject var model: MailModel
    let message: MailSummary
    let detail: MIMEMessage
    @StateObject private var controller = MailReceivedAttachmentsController()

    init(model: MailModel, message: MailSummary, detail: MIMEMessage) {
        self.model = model; self.message = message; self.detail = detail
    }

    var body: some View {
        if !detail.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(detail.attachments.enumerated()), id: \.offset) { index, attachment in
                    HStack(spacing: 8) {
                        Image(systemName: "paperclip")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name).lineLimit(1)
                            Text(Self.subtitle(attachment)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Preview") { controller.perform(.preview, model: model, message: message, detail: detail, index: index) }
                            .controlSize(.small)
                        Button("Open") { controller.perform(.open, model: model, message: message, detail: detail, index: index) }
                            .controlSize(.small)
                        Button("Save") { controller.perform(.save, model: model, message: message, detail: detail, index: index) }
                            .controlSize(.small)
                    }
                }
                if case .loading = controller.state { ProgressView().controlSize(.small) }
                if case .failed(let text) = controller.state { Text(text).font(.caption).foregroundStyle(.red) }
            }
            .sheet(item: $controller.preview) { item in
                MailReceivedAttachmentQuickLook(url: item.url)
                    .frame(minWidth: 540, minHeight: 420)
                    .padding(10)
            }
            .onDisappear { controller.cleanup() }
        }
    }

    private static func subtitle(_ attachment: MIMEMessage.Attachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
        return "\(attachment.mimeType) · \(size)"
    }
}

private struct MailReceivedAttachmentQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
