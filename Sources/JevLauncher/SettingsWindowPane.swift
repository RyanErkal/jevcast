import SwiftUI

struct WindowSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: LauncherModel
    let changed: () -> Void
    private var captionStyle: HierarchicalShapeStyle { preferences.windowShortcuts ? .secondary : .tertiary }
    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .onChange(of: preferences.windowShortcuts) { _, _ in changed() }
        .onChange(of: preferences.edgeSnapping) { _, _ in changed() }
        // The gap applies on the next window action; no shortcut or snapping restart is needed.
        .onChange(of: preferences.gap) { _, gap in model.windows.gap = gap }
    }
}
