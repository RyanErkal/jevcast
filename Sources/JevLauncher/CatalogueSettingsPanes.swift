import Foundation

/// System Settings panes offered as searchable catalogue entries.
///
/// Each entry opens with `x-apple.systempreferences:<pane id>`. Panes are
/// discovered from the settings extensions installed with macOS, so the list
/// matches the running system. Curated titles replace the extensions' internal
/// bundle names (for example `WiFiSettings` becomes `Wi-Fi Settings`).
enum CatalogueSettingsPanes {
    static let extensionsDirectory = "/System/Library/ExtensionKit/Extensions"
    static let systemSettingsPath = "/System/Applications/System Settings.app"
    static let urlScheme = "x-apple.systempreferences:"

    private static let extensionPoint = "com.apple.Settings.extension.ui"

    /// Pane IDs mapped to user-facing titles.
    static let curatedTitles: [String: String] = [
        "com.apple.wifi-settings-extension": "Wi-Fi",
        "com.apple.BluetoothSettings": "Bluetooth",
        "com.apple.Network-Settings.extension": "Network",
        "com.apple.Displays-Settings.extension": "Displays",
        "com.apple.Sound-Settings.extension": "Sound",
        "com.apple.Keyboard-Settings.extension": "Keyboard",
        "com.apple.Trackpad-Settings.extension": "Trackpad",
        "com.apple.Mouse-Settings.extension": "Mouse",
        "com.apple.settings.PrivacySecurity.extension": "Privacy & Security",
        "com.apple.Accessibility-Settings.extension": "Accessibility",
        "com.apple.Notifications-Settings.extension": "Notifications",
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.Desktop-Settings.extension": "Desktop & Dock",
        "com.apple.Appearance-Settings.extension": "Appearance",
        "com.apple.LoginItems-Settings.extension": "Login Items",
        "com.apple.Lock-Screen-Settings.extension": "Lock Screen",
        "com.apple.Users-Groups-Settings.extension": "Users & Groups",
        "com.apple.Software-Update-Settings.extension": "Software Update",
        "com.apple.ControlCenter-Settings.extension": "Control Center",
        "com.apple.Date-Time-Settings.extension": "Date & Time",
        "com.apple.Time-Machine-Settings.extension": "Time Machine",
        "com.apple.Focus-Settings.extension": "Focus",
        "com.apple.Internet-Accounts-Settings.extension": "Internet Accounts",
        "com.apple.CD-DVD-Settings.extension": "CDs & DVDs",
        "com.apple.Siri-Settings.extension": "Siri",
        "com.apple.Wallpaper-Settings.extension": "Wallpaper"
    ]

    /// Panes built into System Settings itself, with no extension bundle.
    static let builtInTitles: [String: String] = [
        "com.apple.systempreferences.GeneralSettings": "General"
    ]

    /// Returns one entry per settings pane found in ``directory``. When the
    /// directory has no readable settings extensions, the curated list is
    /// used instead so the common panes stay searchable.
    nonisolated static func entries(in directory: String = extensionsDirectory) -> [AppEntry] {
        var titles: [String: String] = builtInTitles
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        var discovered = false
        for name in names where name.hasSuffix(".appex") {
            if Task.isCancelled { return [] }
            let plistURL = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
                .appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let paneID = paneID(fromInfo: info) else { continue }
            discovered = true
            if let title = curatedTitles[paneID] ?? readableTitle(info) {
                titles[paneID] = title
            }
        }
        if !discovered {
            titles.merge(curatedTitles) { current, _ in current }
        }
        return titles.map { paneID, title in
            AppEntry(path: systemSettingsPath, name: title + " Settings", bundleID: nil, launchURL: urlScheme + paneID)
        }
    }

    /// Returns the pane ID when ``info`` declares a settings extension that
    /// accepts `x-apple.systempreferences` URLs.
    nonisolated static func paneID(fromInfo info: [String: Any]) -> String? {
        guard let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String == extensionPoint,
              let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
              (settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool) == true,
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return nil }
        return identifier
    }

    /// Uses an extension's display name only when it reads like a pane title.
    /// Internal names such as `MouseExtension` or `LoginItems` are skipped.
    private nonisolated static func readableTitle(_ info: [String: Any]) -> String? {
        guard let name = info["CFBundleDisplayName"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("_") else { return nil }
        for word in ["Extension", "Settings", "Preference", "Pane"] where trimmed.contains(word) { return nil }
        // Reject joined CamelCase words such as "FollowUp".
        let scalars = Array(trimmed.unicodeScalars)
        for index in scalars.indices.dropFirst()
        where CharacterSet.uppercaseLetters.contains(scalars[index])
            && CharacterSet.lowercaseLetters.contains(scalars[index - 1]) {
            return nil
        }
        return trimmed
    }
}
