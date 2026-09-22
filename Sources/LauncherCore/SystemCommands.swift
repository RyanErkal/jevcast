import Foundation

/// A built-in command. Every step is a fixed executable with fixed arguments,
/// run directly, without a shell. Nothing in a step comes from typed text or Jev.
public struct SystemCommand: Identifiable, Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        /// Wait for the steps to finish. A failure is shown.
        case none
        /// Wait, then copy the trimmed standard output.
        case copy
        /// Start the step and do not wait, for long-running tools such as caffeinate.
        case background
    }
    /// A stable ID. The launcher stores "command:" + id for ranking and favourites.
    public let id: String
    public let title: String
    public let aliases: [String]
    /// A short description for Jev. It never holds a path.
    public let detail: String
    public let symbol: String
    public let steps: [[String]]
    /// Destructive or disruptive commands need a second Return.
    public let confirm: Bool
    public let output: Output

    public init(id: String, title: String, aliases: [String], detail: String, symbol: String,
                steps: [[String]], confirm: Bool = false, output: Output = .none) {
        self.id = id; self.title = title; self.aliases = aliases; self.detail = detail
        self.symbol = symbol; self.steps = steps; self.confirm = confirm; self.output = output
    }
}

public enum SystemCommands {
    private static let osascript = "/usr/bin/osascript"
    private static let killall = "/usr/bin/killall"
    private static let defaults = "/usr/bin/defaults"

    public static let all: [SystemCommand] = [
        SystemCommand(id: "sleep-display", title: "Sleep Display", aliases: ["screen off", "display off", "turn off screen"],
                      detail: "Turn the display off now", symbol: "display", steps: [["/usr/bin/pmset", "displaysleepnow"]]),
        SystemCommand(id: "sleep-mac", title: "Sleep Mac", aliases: ["sleep", "sleep now", "go to sleep"],
                      detail: "Put the Mac to sleep", symbol: "moon.zzz", steps: [["/usr/bin/pmset", "sleepnow"]], confirm: true),
        SystemCommand(id: "dark-mode", title: "Toggle Dark Mode", aliases: ["dark mode", "light mode", "appearance"],
                      detail: "Switch between light and dark appearance", symbol: "circle.lefthalf.filled",
                      steps: [[osascript, "-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"]]),
        SystemCommand(id: "show-hidden-files", title: "Show Hidden Files", aliases: ["hidden files", "dotfiles", "show dotfiles"],
                      detail: "Show hidden files in Finder", symbol: "eye",
                      steps: [[defaults, "write", "com.apple.finder", "AppleShowAllFiles", "-bool", "true"], [killall, "Finder"]]),
        SystemCommand(id: "hide-hidden-files", title: "Hide Hidden Files", aliases: ["hide dotfiles"],
                      detail: "Hide hidden files in Finder", symbol: "eye.slash",
                      steps: [[defaults, "write", "com.apple.finder", "AppleShowAllFiles", "-bool", "false"], [killall, "Finder"]]),
        SystemCommand(id: "restart-finder", title: "Restart Finder", aliases: ["relaunch finder", "kill finder"],
                      detail: "Quit and reopen Finder", symbol: "arrow.clockwise", steps: [[killall, "Finder"]]),
        SystemCommand(id: "restart-dock", title: "Restart Dock", aliases: ["relaunch dock", "kill dock"],
                      detail: "Quit and reopen the Dock", symbol: "dock.rectangle", steps: [[killall, "Dock"]]),
        SystemCommand(id: "empty-trash", title: "Empty Trash", aliases: ["clear trash", "delete trash"],
                      detail: "Permanently delete the items in the Trash", symbol: "trash",
                      steps: [[osascript, "-e", "tell application \"Finder\" to empty trash"]], confirm: true),
        SystemCommand(id: "eject-all", title: "Eject All Disks", aliases: ["eject", "eject disks", "unmount"],
                      detail: "Eject every external disk", symbol: "eject",
                      steps: [[osascript, "-e", "tell application \"Finder\" to eject (every disk whose ejectable is true)"]], confirm: true),
        SystemCommand(id: "mute", title: "Mute Sound", aliases: ["mute", "silence", "sound off"],
                      detail: "Mute the Mac's sound output", symbol: "speaker.slash",
                      steps: [[osascript, "-e", "set volume output muted true"]]),
        SystemCommand(id: "unmute", title: "Unmute Sound", aliases: ["unmute", "sound on"],
                      detail: "Unmute the Mac's sound output", symbol: "speaker.wave.2",
                      steps: [[osascript, "-e", "set volume output muted false"]]),
        SystemCommand(id: "screenshot-area", title: "Screenshot Area to Clipboard", aliases: ["screenshot", "screen capture", "capture area"],
                      detail: "Select an area and copy a screenshot of it", symbol: "camera.viewfinder",
                      steps: [["/usr/sbin/screencapture", "-i", "-c"]]),
        SystemCommand(id: "local-ip", title: "Copy Local IP Address", aliases: ["ip", "ip address", "my ip", "local ip"],
                      detail: "Copy this Mac's Wi-Fi IP address on the local network", symbol: "network",
                      steps: [["/usr/sbin/ipconfig", "getifaddr", "en0"]], output: .copy),
        SystemCommand(id: "keep-awake", title: "Keep Mac Awake for 1 Hour", aliases: ["caffeinate", "keep awake", "stay awake", "no sleep"],
                      detail: "Stop the Mac and display from sleeping for one hour", symbol: "cup.and.saucer",
                      steps: [["/usr/bin/caffeinate", "-di", "-t", "3600"]], output: .background)
    ]

    public static func command(id: String) -> SystemCommand? { all.first { $0.id == id } }
}
