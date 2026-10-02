import Foundation
import LauncherCore

/// Stages immutable bytes chosen in the composer. Never passes the user's original path to Mail.
final class MailAttachmentStaging {
    let directory: URL
    let paths: [String]
    init(_ attachments: [OutgoingMessage.Attachment]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-mail-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var selected: [String] = []
        do {
            for (index, attachment) in attachments.enumerated() {
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let name = String(attachment.filename.unicodeScalars.map { $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == ":" ? "_" : Character($0) })
                let file = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "attachment" : String(name.prefix(180)))
                try attachment.data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                selected.append(file.path)
            }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        paths = selected
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
