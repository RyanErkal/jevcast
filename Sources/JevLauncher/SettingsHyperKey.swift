import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LauncherCore

/// One key: the recorder, what it does, and a clear button.
struct HyperBindingRow: View {
    @Binding var binding: HyperBinding
    let duplicate: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            KeyRecorder(keyCode: $binding.keyCode)
                .frame(width: 104, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
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
            HStack(spacing: 4) {
                Keycap("⇪")
                Text("+").font(.caption).foregroundStyle(.tertiary)
                if monitor == nil { Keycap(HyperLayer.keyName(keyCode)) }
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
