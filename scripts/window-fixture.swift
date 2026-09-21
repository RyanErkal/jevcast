import AppKit

// Separate process used to test AX window commands without moving user documents.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 180 + index * 70, y: 180 + index * 70, width: 720, height: 480), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Jev Window Test \(index + 1)"
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "Jev Launcher window test\n\nThis window contains no user data.\nTry halves, quarters, thirds, maximise, and restore.")
            label.font = .systemFont(ofSize: 22)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(label)
            if let view = window.contentView {
                NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            }
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
