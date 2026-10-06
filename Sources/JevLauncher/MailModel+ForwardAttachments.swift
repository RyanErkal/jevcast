import Foundation
import LauncherCore

extension MailModel {
    /// Only a forward retains non-inline attachment bytes. Reading and prefetching do not fill
    /// the body cache with attachment payloads.
    func captureForwardAttachments() {
        guard let current = draft, current.mode == .forward, let original = current.original,
              let source = current.source, source.forwardAttachments == nil else { return }
        if source.message.attachments.isEmpty {
            draft?.source = .init(rowID: source.rowID, message: source.message, html: source.html, forwardAttachments: [])
            return
        }
        let context: MailReceivedAttachmentContext
        guard current.backend == MailBackend.current.rawValue, let root, let box = mailbox(original.mailbox),
              let identity = mailIndexIdentity else { banner = "Open the original message again to keep its attachments."; return }
        context = .init(root: root, mailbox: box, message: original, detail: source.message,
                        backend: NativeMailCenter.isNativeRoot(root) ? .jevcast : .appleMail,
                        indexIdentity: .init(device: identity.device, inode: identity.inode))
        Task { @MainActor [weak self] in
            do {
                let files = try await MailReceivedAttachmentLoader.load(context)
                guard let self, self.draft?.id == current.id, self.draft?.source?.rowID == source.rowID else { return }
                let attachments = files.map { OutgoingMessage.Attachment(filename: $0.name, mimeType: $0.mimeType, data: $0.data) }
                self.draft?.source = .init(rowID: source.rowID, message: source.message, html: source.html, forwardAttachments: attachments)
            } catch {
                guard let self, self.draft?.id == current.id else { return }
                self.banner = "The forward attachments could not be kept: " + error.localizedDescription
            }
        }
    }
}
