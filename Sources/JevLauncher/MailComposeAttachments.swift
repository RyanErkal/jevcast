import AppKit
import LauncherCore
import UniformTypeIdentifiers

enum MailComposeAttachments {
    static let byteLimit = 18 * 1024 * 1024
    static func read(_ url: URL, inline: Bool) throws -> OutgoingMessage.Attachment {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LauncherError("The selected file could not be read. Select a regular file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= byteLimit else {
            throw LauncherError("Select a regular file smaller than 18 MB.")
        }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw LauncherError("The selected file is larger than 18 MB.") }
        let type = UTType(filenameExtension: url.pathExtension)
        if inline && type?.conforms(to: .image) != true { throw LauncherError("Select an image for Insert Image.") }
        return .init(filename: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data,
                     contentID: inline ? UUID().uuidString.lowercased() + "@jevcast.local" : nil)
    }
}

extension MailModel {
    func pickAttachments(inline: Bool = false) {
        guard let id = draft?.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = !inline
        panel.prompt = inline ? "Insert Image" : "Attach"
        if inline { panel.allowedContentTypes = [.image] }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                do {
                    let attachments = try await Task.detached { try urls.map { try MailComposeAttachments.read($0, inline: inline) } }.value
                    guard let self, self.draft?.id == id, let draft = self.draft else { return }
                    guard draft.attachments.count + attachments.count <= 30,
                          (draft.attachments + attachments).reduce(0, { $0 + $1.data.count }) <= MailComposeAttachments.byteLimit else {
                        throw LauncherError("Attachments must total 18 MB or less, with no more than 30 files.")
                    }
                    self.draft?.attachments += attachments
                } catch { self?.composeNote = error.localizedDescription }
            }
        }
    }
}
