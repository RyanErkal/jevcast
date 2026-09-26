import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// Settings › Windows › Hyper key: the switch, its status, and the key layer.
struct HyperKeySettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: HyperKeyController
    let resized: () -> Void

    var body: some View {
        Section {
            Toggle("Use Caps Lock as a Hyper key", isOn: $preferences.hyperKeyEnabled)
            Text("Hold Caps Lock and press a key below. Caps Lock never types capitals while this is on; its light shows while you hold it. Quit Jevcast and Caps Lock works as before.")
                .font(.caption).foregroundStyle(.secondary)
            if preferences.hyperKeyEnabled { status }
        } header: { Text("Hyper key") }
        Section {
            ForEach($preferences.hyperBindings) { $binding in
                HyperBindingRow(binding: $binding, duplicate: duplicates.contains(binding.keyCode)) {
                    preferences.hyperBindings.removeAll { $0.id == binding.id }
                }
            }
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
        } header: { Text("Keys") }
        .onChange(of: preferences.hyperBindings.count) { _, _ in resized() }
        .onChange(of: preferences.hyperKeyEnabled) { _, _ in resized() }
    }

    private var duplicates: Set<UInt16> { HyperLayer.duplicateKeys(preferences.hyperBindings) }

    @ViewBuilder private var status: some View {
        if !controller.tapRunning {
            HStack {
                Label("Jevcast cannot see the keyboard yet. Allow Accessibility and Input Monitoring.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Accessibility…") { Permission.accessibility.openSystemSettings() }.controlSize(.small)
                Button("Input Monitoring…") { Permission.requestInputMonitoring() }.controlSize(.small)
            }
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

/// One key: the recorder, what it does, and a clear button.
private struct HyperBindingRow: View {
    @Binding var binding: HyperBinding
    let duplicate: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            KeyRecorder(keyCode: $binding.keyCode)
                .frame(width: 110, alignment: .leading)
            if duplicate {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("This key is used by another row.")
            }
            Menu(HyperActionTitle.of(binding.action)) {
                Section("Jevcast") {
                    ForEach(HyperBuiltIn.allCases, id: \.self) { item in
                        Button(item.title) { binding.action = .builtIn(item.rawValue) }
                    }
                }
                Section("Send a key") {
                    ForEach(HyperLayer.sendableKeys, id: \.self) { code in
                        Button("Send " + HyperLayer.keyName(code)) { binding.action = .sendKey(code) }
                    }
                }
                Button("Open App…") { if let id = Self.chooseApp() { binding.action = .openApp(id) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Clear this key")
                .accessibilityLabel("Clear Hyper \(HyperLayer.keyName(binding.keyCode))")
        }
    }

    /// Picks an app; only its bundle ID is kept.
    private static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

enum HyperActionTitle {
    @MainActor static func of(_ action: HyperAction) -> String {
        switch action {
        case .builtIn(let id): return HyperBuiltIn(rawValue: id)?.title ?? "Unknown action"
        case .sendKey(let code): return "Send " + HyperLayer.keyName(code)
        case .openApp(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "Open \(id) (not found)" }
            return "Open " + FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }
}

/// Shows "Hyper" and the key; click, then press a key to change it. Escape cancels.
struct KeyRecorder: View {
    @Binding var keyCode: UInt16
    @State private var monitor: Any?

    var body: some View {
        Button {
            monitor == nil ? start() : stop()
        } label: {
            HStack(spacing: 3) {
                KeyChip("Hyper")
                if monitor == nil { KeyChip(HyperLayer.keyName(keyCode)) }
                else { Text("Press a key…").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        .help("Click, then press the key to use with Hyper")
        .accessibilityLabel("Hyper \(HyperLayer.keyName(keyCode)). Press to record a new key.")
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != 53 { keyCode = event.keyCode }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
