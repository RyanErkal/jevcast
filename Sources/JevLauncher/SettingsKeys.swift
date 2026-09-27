import SwiftUI
import LauncherCore

/// Settings › Windows › Keys: the Hyper key and its layer first, then every other shortcut.
struct KeysSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: HyperKeyController
    let resized: () -> Void

    var body: some View {
        Section {
            Toggle("Use Caps Lock as a Hyper key", isOn: $preferences.hyperKeyEnabled)
            Text("Hold Caps Lock (⇪) and press a key below. While this is on, Caps Lock does not type capitals. When you quit \(AppIdentity.name), Caps Lock works as before.")
                .font(.caption).foregroundStyle(.secondary)
            if preferences.hyperKeyEnabled { status }
        } header: { Text("Hyper key") }
        ForEach(HyperGroup.allCases, id: \.self) { group in
            if preferences.hyperBindings.contains(where: { HyperGroup.of($0.action) == group }) {
                Section {
                    ForEach($preferences.hyperBindings) { $binding in
                        if HyperGroup.of(binding.action) == group {
                            HyperBindingRow(binding: $binding, duplicate: duplicates.contains(binding.keyCode)) {
                                preferences.hyperBindings.removeAll { $0.id == binding.id }
                            }
                        }
                    }
                } header: { Text("Hyper · " + group.rawValue) }
            }
        }
        Section {
            if !duplicates.isEmpty {
                Label("A key is used twice. Only the first row runs.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Add Key") { addBinding() }.controlSize(.small)
                Spacer()
                Button("Restore Defaults") { preferences.hyperBindings = HyperLayer.defaults }.controlSize(.small)
                    .disabled(preferences.hyperBindings == HyperLayer.defaults)
            }
        } footer: {
            Text("Click a key to record a new one. Choose Open App… for an app of your own.")
                .font(.caption).foregroundStyle(.secondary)
        }
        KeyReference(preferences: preferences)
            .onChange(of: preferences.hyperBindings) { _, _ in resized() }
            .onChange(of: preferences.hyperKeyEnabled) { _, _ in resized() }
    }

    private var duplicates: Set<UInt16> { HyperLayer.duplicateKeys(preferences.hyperBindings) }

    @ViewBuilder private var status: some View {
        if !controller.tapRunning {
            Label("\(AppIdentity.name) cannot read the keyboard yet. Allow both permissions below.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            PermissionRow(permission: .accessibility)
            PermissionRow(permission: .inputMonitoring, request: Permission.requestInputMonitoring)
        }
        if let error = controller.remapError {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
        if !controller.lightAvailable {
            Text("The Caps Lock light needs Input Monitoring. The Hyper key works without it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A new row on the first free letter, opening the launcher until the user changes it.
    private func addBinding() {
        let used = Set(preferences.hyperBindings.map(\.keyCode))
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let key = letters.first { !used.contains($0) } ?? 0
        preferences.hyperBindings.append(HyperBinding(keyCode: key, action: .builtIn(HyperBuiltIn.launcher.rawValue)))
    }
}

/// How the Keys part groups Hyper rows. Display only; nothing is stored.
enum HyperGroup: String, CaseIterable {
    case views = "Jevcast views", navigation = "Navigation", windows = "Windows", apps = "Apps"
    static func of(_ action: HyperAction) -> HyperGroup {
        switch action {
        case .builtIn(let id): return HyperBuiltIn(rawValue: id)?.windowAction == nil ? .views : .windows
        case .sendKey: return .navigation
        case .openApp: return .apps
        }
    }
}

/// A keyboard key: rounded, lightly filled, monospaced glyph.
struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .frame(minWidth: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
    }
}
