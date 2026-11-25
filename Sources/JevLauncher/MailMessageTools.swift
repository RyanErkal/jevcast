import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// Snooze for the selected message, when its account can snooze on this Mac.
struct MailSnoozeTool: View {
    @ObservedObject var model: MailModel
    @ObservedObject var features: MailFeatureCenter
    var body: some View {
        if let message = model.selected, let box = model.actionBox(message),
           let account = features.accountChoices.first(where: { $0.id == box.accountID }) {
            MailSnoozeButton(message: message, account: .init(accountID: account.id, address: account.title),
                messageID: model.detail?.header("Message-ID"), center: features.snoozes, showingEditor: $model.snoozeEditorOpen)
                .labelStyle(.iconOnly).accessibilityLabel("Snooze")
        }
    }

    /// True when the selected message can be snoozed: the toolbar keeps a place for it.
    @MainActor static func available(_ model: MailModel, _ features: MailFeatureCenter?) -> Bool {
        guard let features, let message = model.selected, let box = model.actionBox(message) else { return false }
        return features.accountChoices.contains { $0.id == box.accountID }
    }
}

enum MailMessageExport {
    /// Saves the messages as one `.eml` or `.mbox` file where you choose. `busy` is true while it runs.
    @MainActor
    static func run(_ messages: [MailSummary], format: MailArchiveFormat, model: MailModel, features: MailFeatureCenter,
                    busy: @escaping @MainActor (Bool) -> Void) {
        guard let root = model.root, !messages.isEmpty else { return }
        let targets = messages.compactMap { message in model.actionBox(message).map { (message, $0) } }
        guard targets.count == messages.count else { model.banner = "Refresh Mail before exporting these messages."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format == .eml ? "eml" : "mbox") ?? .data]
        panel.nameFieldStringValue = MailArchiveStore.safeFilename(messages.count == 1 ? messages[0].subject : "Mail") + (format == .eml ? ".eml" : ".mbox")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy(true)
        Task {
            defer { busy(false) }
            do {
                let store = try features.archive()
                var raw: [Data] = []
                for (message, box) in targets {
                    if NativeMailCenter.isNativeRoot(root), let engine = NativeMailCenter.activeEngine { try await engine.fetchBody(message.rowID) }
                    let bytes = try await Task.detached(priority: .utility) {
                        try MailMessageExport.read(root: root, message: message, box: box)
                    }.value
                    raw.append(bytes)
                }
                let bytes = raw
                let result = try await Task.detached(priority: .utility) {
                    try store.exportNative(rawMessages: bytes, format: format, to: destination, overwrite: true)
                }.value
                model.banner = "Exported \(result.messageCount) message(s)."
            } catch { model.banner = error.localizedDescription }
        }
    }

    static func read(root: String, message: MailSummary, box: MailMailbox) throws -> Data {
        let current = try MailStore.messages(root: root, .init(mailboxes: [box.rowID], rowIDs: [message.rowID], limit: 1))
        guard let row = current.first, row.messageKey == message.messageKey, row.subject == message.subject,
              row.senderAddress == message.senderAddress,
              let path = MailStore.messageFile(root: root, mailbox: box, rowID: message.rowID) else {
            throw LauncherError("This message changed or has not been downloaded. Refresh Mail before exporting it.")
        }
        return try rawEMLX(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func rawEMLX(_ data: Data) throws -> Data {
        guard let newline = data.firstIndex(of: 10),
              let count = Int(String(decoding: data[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              count > 0, count <= data.count - newline - 1 else {
            throw LauncherError("The downloaded message is incomplete. Nothing was exported.")
        }
        return data.subdata(in: (newline + 1)..<(newline + 1 + count))
    }
}
