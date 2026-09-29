import AppKit
import GhosttyKit

/// The one libghostty app in the process, made when the Terminal view first opens. It reads the
/// user's Ghostty config, then `TerminalStyle` on top, and reloads both when the appearance
/// changes. libghostty calls back on the main thread, except for wakeups.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    /// Nil when libghostty could not start.
    private(set) var app: ghostty_app_t?
    private var keyboardObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?
    /// The config in use. Kept until a newer one replaces it.
    private var config: ghostty_config_t?
    private var dark = false

    private init() {
        // libghostty keeps argv. Only the program name goes in, so Jevcast's own flags never reach it.
        dark = Self.isDark
        guard ghostty_init(1, CommandLine.unsafeArgv) == GHOSTTY_SUCCESS, let config = Self.makeConfig(dark: dark) else { return }
        self.config = config
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.tick() } } },
            action_cb: { _, target, action in MainActor.assumeIsolated { GhosttyRuntime.perform(action, on: target) } },
            read_clipboard_cb: { userdata, location, state in
                MainActor.assumeIsolated { TerminalView.from(userdata)?.readClipboard(location, state: state) ?? false }
            },
            confirm_read_clipboard_cb: { userdata, text, state, request in
                let text = text.map { String(cString: $0) } ?? ""
                MainActor.assumeIsolated { TerminalView.from(userdata)?.confirmClipboard(text, state: state, request: request) }
            },
            write_clipboard_cb: { _, location, content, count, confirm in
                // Only plain text, and only writes that need no confirmation.
                guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let content else { return }
                let text = (0..<count).lazy.map { content[$0] }
                    .first { $0.mime.map { String(cString: $0) } == "text/plain" }?.data.map { String(cString: $0) }
                guard let text else { return }
                MainActor.assumeIsolated {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            },
            close_surface_cb: { userdata, _ in MainActor.assumeIsolated { TerminalView.from(userdata)?.closeLater() } }
        )
        guard let app = ghostty_app_new(&runtime, config) else { return }
        self.app = app
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        // The launcher follows the system appearance, and the terminal's colours follow it too.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GhosttyRuntime.shared.appearanceChanged() } }
        }
        // App focus follows the terminal (TerminalView.setFocused), since the launcher never activates Jevcast.
        keyboardObserver = NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                                                                  object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) } }
        }
    }

    private func tick() {
        if let app { ghostty_app_tick(app) }
    }

    private static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The user's Ghostty config files, then Jevcast's style, so the style's keys win.
    private static func makeConfig(dark: Bool) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        if let style = TerminalStyle.file(dark: dark) { style.path.withCString { ghostty_config_load_file(config, $0) } }
        ghostty_config_finalize(config)
        return config
    }

    private func appearanceChanged() {
        let dark = Self.isDark
        guard let app, dark != self.dark, let config = Self.makeConfig(dark: dark) else { return }
        self.dark = dark
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        ghostty_app_update_config(app, config)
        if let old = self.config { ghostty_config_free(old) }
        self.config = config
    }

    /// The few libghostty actions a single window needs. Returning false lets libghostty fall back.
    private static func perform(_ action: ghostty_action_s, on target: ghostty_target_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let view = TerminalView.from(ghostty_surface_userdata(surface)) else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return false }
            view.onTitle?(String(cString: title))
            return true
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            view.closeLater()
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // A link you ⌘-clicked, such as a sign-in page. Only web links open.
            let link = action.action.open_url
            guard let pointer = link.url else { return false }
            let text = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: Int(link.len)), as: UTF8.self)
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            Frontmost.open(url)
            return true
        default:
            return false
        }
    }
}
