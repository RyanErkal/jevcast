import AppKit

/// Ghostty settings that make the terminal part of the launcher: no background of its own over
/// the panel glass, the launcher's margins, an accent bar cursor like the search field's, and
/// text and selection colours for the appearance. They load after the user's Ghostty config, so
/// only these keys change; the font, palette, and keybinds stay the user's.
enum TerminalStyle {
    /// A file, because libghostty loads config only from files. It holds no personal data.
    static func file(dark: Bool) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jevcast-terminal-\(dark ? "dark" : "light").ghostty")
        do { try text(dark: dark).write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }

    static func text(dark: Bool) -> String {
        var accent = "", selection = ""
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            accent = hex(.controlAccentColor)
            selection = hex(.selectedTextBackgroundColor)
        }
        // The background colour is never drawn at opacity 0. libghostty still uses it for reversed
        // text and for minimum contrast, so it is close to the glass in each appearance.
        return """
        background-opacity = 0
        background = \(dark ? "1f1f21" : "f5f5f7")
        foreground = \(dark ? "dcdcdd" : "262626")
        \(dark ? "" : "minimum-contrast = 3")
        window-padding-x = \(Int(LauncherMetrics.gutter))
        window-padding-y = 10
        window-padding-balance = false
        cursor-style = bar
        cursor-color = \(accent)
        selection-background = \(selection)
        selection-foreground = cell-foreground

        """
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "808080" }
        let byte = { (value: CGFloat) in Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
