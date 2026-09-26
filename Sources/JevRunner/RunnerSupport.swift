import AppKit
import Foundation
import LauncherCore
import Security

/// Holds `runner.lock` with flock for the life of the process, so only one runner works at a time.
/// The file is never unlinked.
enum SingleInstance {
    static func acquire(root: URL) -> Int32? {
        try? AutomationStore(root: root).acquireRunnerLock()
    }
}

enum RunnerIdentity {
    static let appBundleID = "com.ryanerkal.jevlauncher"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// True when this binary has a real (not ad hoc) signature.
    static var signedBuild: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return dict[kSecCodeInfoIdentifier as String] != nil && flags & SecCodeSignatureFlags.adhoc.rawValue == 0
    }

    /// `.../Jevcast.app` when this runs from `Jevcast.app/Contents/MacOS/jevcast-runner`.
    static var containingApp: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

/// Opens the app in the background so it can show the notch alert. Never activates it.
enum AlertLauncher {
    static func openAppIfNeeded() {
        DispatchQueue.main.async {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: RunnerIdentity.appBundleID).isEmpty,
                  let app = RunnerIdentity.containingApp else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            config.arguments = ["--automation-alerts"]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                if let error { log("Could not open the app for an alert: \(error.localizedDescription)") }
            }
        }
    }

    static func shouldAlert(_ run: RunRecord, policy: Policy) -> Bool {
        switch run.state {
        case .needsInput, .needsApproval: return true
        case .failed: return policy.alertOnFailure
        case .succeeded: return false
        default: return false
        }
    }
}

/// Script secrets from the Keychain. Never shows a prompt; a locked or denied item reads as missing.
enum SecretStore {
    static let service = "com.ryanerkal.jevlauncher.automations"

    static func value(_ name: String) -> String? {
        let context = LAContextless.query(service: service, account: name)
        var out: CFTypeRef?
        guard SecItemCopyMatching(context as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private enum LAContextless {
    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("jevcast-runner: \(message)\n".utf8))
}
