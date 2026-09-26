import SwiftUI

/// Settings › Windows: window moves, and the Hyper key.
struct WindowSettings: View {
    enum Part: String, CaseIterable { case windows = "Windows", hyper = "Hyper key" }
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: LauncherModel
    let hyper: HyperKeyController
    let changed: () -> Void
    let resized: () -> Void
    @AppStorage("settingsWindowsPart") private var part: Part = .windows
    var body: some View {
        Form {
            Section { PaneSections(selection: $part) }
            switch part {
            case .windows: windowSections
            case .hyper: HyperKeySettings(preferences: preferences, controller: hyper, resized: resized)
            }
        }
        .formStyle(.grouped)
        .onChange(of: part) { _, _ in resized() }
    }
}

private extension WindowSettings {
    private var captionStyle: HierarchicalShapeStyle { preferences.windowShortcuts ? .secondary : .tertiary }
    @ViewBuilder var windowSections: some View {
        Group {
            Section("Permissions") {
                PermissionRow(permission: .accessibility) { model.windows.requestPermission() }
            }
            Section {
                Toggle("Snap windows dragged to screen edges", isOn: $preferences.edgeSnapping)
                Toggle("Use direct window shortcuts", isOn: $preferences.windowShortcuts)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hold Control–Option–Command, then press").font(.caption).foregroundStyle(captionStyle)
                    ShortcutTable()
                    Text("Press a half or the centre third again to cycle its size.")
                        .font(.caption).foregroundStyle(captionStyle)
                }
                .disabled(!preferences.windowShortcuts)
            } header: { Text("Behaviour") }
            Section("Layout") {
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: $preferences.gap, in: 0...24, step: 1).frame(width: 180)
                            .accessibilityValue("\(Int(preferences.gap)) points")
                        Text("\(Int(preferences.gap)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .onChange(of: preferences.windowShortcuts) { _, _ in changed() }
        .onChange(of: preferences.edgeSnapping) { _, _ in changed() }
        // The gap applies on the next window action; no shortcut or snapping restart is needed.
        .onChange(of: preferences.gap) { _, gap in model.windows.gap = gap }
    }
}
