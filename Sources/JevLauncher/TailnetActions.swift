import AppKit
import LauncherCore
import UniformTypeIdentifiers

/// What a device row can do: show its screen, send it files, and copy how to reach it. Each action opens
/// a fixed kind of link, or runs the Tailscale CLI with fixed arguments and the files you choose.
@MainActor
enum TailnetActions {
    /// The first verb is what Return does.
    static func verbs(for device: TailnetDevice) -> [Verb] {
        var verbs: [Verb] = []
        if !device.isSelf, let ip = device.ipv4 {
            if device.isWindows { verbs.append(remoteDesktop(device, ip: ip)) }
            if device.os.lowercased() == "macos" { verbs.append(open("Screen Sharing", "vnc://\(ip)")) }
            if device.acceptsFiles, device.online { verbs.append(sendFiles(device, ip: ip)) }
            verbs.append(copy("Copy SSH Command", "ssh " + (device.dnsName.isEmpty ? ip : device.dnsName)))
        }
        if !device.dnsName.isEmpty { verbs.append(copy("Copy Name", device.dnsName)) }
        if let ip = device.ipv4 { verbs.append(copy("Copy IP Address", ip)) }
        return verbs
    }

    static func copy(_ title: String, _ text: String) -> Verb {
        Verb(title: title, after: .keepOpen) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return "Copied \(text)"
        }
    }

    /// Opens a Remote Desktop file for the PC in Windows App, Microsoft's client from the App Store.
    private static func remoteDesktop(_ device: TailnetDevice, ip: String) -> Verb {
        guard let type = UTType(filenameExtension: "rdp"), NSWorkspace.shared.urlForApplication(toOpen: type) != nil else {
            return Verb(title: "Remote Desktop", after: .keepOpen) { "Install Windows App from the App Store to use Remote Desktop." }
        }
        return Verb(title: "Remote Desktop", after: .closeKeepFocus) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Jevcast Remote Desktop", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(device.name.replacingOccurrences(of: "/", with: "-") + ".rdp")
            // The address only. Windows App asks for the account.
            try "full address:s:\(ip):3389\r\nprompt for credentials:i:1\r\n".write(to: file, atomically: true, encoding: .utf8)
            guard Frontmost.open(file) else { throw CommandRunner.Failure(text: "Remote Desktop could not open.") }
            return nil
        }
    }

    private static func open(_ title: String, _ link: String) -> Verb {
        Verb(title: title, after: .closeKeepFocus) {
            guard let url = URL(string: link), Frontmost.open(url) else { throw CommandRunner.Failure(text: "\(title) could not open.") }
            return nil
        }
    }

    /// Taildrop: the files you choose go to the device through `tailscale file cp`. A notification says when they arrive.
    private static func sendFiles(_ device: TailnetDevice, ip: String) -> Verb {
        Verb(title: "Send Files…", after: .closeKeepFocus) {
            guard let cli = TailscaleReader.cli else { throw CommandRunner.Failure(text: "Tailscale is not installed on this Mac.") }
            NSApp.activate()
            let panel = NSOpenPanel()
            panel.title = "Send Files to \(device.name)"
            panel.prompt = "Send"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
            let paths = panel.urls.map(\.path)
            // Full paths start with "/", so no file name reads as an option.
            _ = try await CommandRunner.capture([cli, "file", "cp", "--update-interval=0"] + paths + [ip + ":"])
            let sent = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
            _ = await Notifier.post(title: "Sent to \(device.name)", body: sent)
            return nil
        }
    }
}
