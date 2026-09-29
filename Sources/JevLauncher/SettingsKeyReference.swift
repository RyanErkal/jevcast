import SwiftUI

/// Read-only list of the shortcuts that are not on the Hyper layer.
struct KeyReference: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Section {
            row(launcherKeys, "Open the launcher", note: "Change it in General.")
            row(["Right ⌘"], "Hold to dictate", note: preferences.dictationEnabled ? nil : "Off. Turn it on in Voice › Dictation.")
        } header: { Text("Global") }
        Section {
            row(["⌃", "⌥", "⌘", "←", "→", "↑", "↓"], "Halves")
            row(["⌃", "⌥", "⌘", "U", "I", "J", "K"], "Quarters")
            row(["⌃", "⌥", "⌘", "1", "2", "3"], "Thirds")
            row(["⌃", "⌥", "⌘", "↩"], "Maximise")
            row(["⌃", "⌥", "⌘", "Z"], "Restore")
            row(["⌃", "⌥", "⌘", "N", "P"], "Next / previous display")
        } header: { Text("Windows") } footer: {
            Text(preferences.windowShortcuts ? "Turn these off in Windows." : "Off. Turn on direct window shortcuts in Windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            row(["↩"], "Open the selected item")
            row(["⇧", "↩"], "Paste instead of copy", note: "Answers, emoji, snippets, clipboard items, and Quill answers.")
            row(["⌘", "K"], "Show actions")
            row(["⌘", "Y"], "Quick Look", note: "Files, folders, and apps.")
            row(["⌘", "R"], "Show in Finder")
            row(["⌘", "⇧", "C"], "Copy the path")
            row(["⌘", "Z"], "Undo a Jev or remembered pick", note: "Jevcast forgets that answer.")
            row(["⎋"], "Go back, or close")
            row(["⌘", "O"], "Open a view in its own window")
            row(["Space"], "Expand mail, or Quick Look a clip", note: "Mail and Clipboard views.")
        } header: { Text("In the launcher") }
    }

    private var launcherKeys: [String] {
        switch preferences.hotkey {
        case .controlShiftSpace: return ["⌃", "⇧", "Space"]
        case .optionSpace: return ["⌥", "Space"]
        case .commandSpace: return ["⌘", "Space"]
        }
    }

    private func row(_ keys: [String], _ action: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 3) { ForEach(Array(keys.enumerated()), id: \.offset) { Keycap($0.element) } }
                .frame(width: 190, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(action)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(action + ": " + keys.joined(separator: " "))
            Spacer(minLength: 0)
        }
    }
}
