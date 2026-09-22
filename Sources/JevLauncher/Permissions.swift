import AppKit
import AVFoundation
import Speech

enum Permission: CaseIterable {
    case microphone, speech, accessibility

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .accessibility: return "Accessibility"
        }
    }
    var purpose: String {
        switch self {
        case .microphone: return "Hears spoken commands"
        case .speech: return "Transcribes speech on this Mac"
        case .accessibility: return "Moves and resizes windows"
        }
    }
    @MainActor var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: return WindowManager.hasPermission
        }
    }
    private var pane: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .speech: return "Privacy_SpeechRecognition"
        case .accessibility: return "Privacy_Accessibility"
        }
    }
    /// True before the first request. Accessibility has no such state: it is granted in System Settings.
    @MainActor var isUndetermined: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .speech: return SFSpeechRecognizer.authorizationStatus() == .notDetermined
        case .accessibility: return false
        }
    }
    /// Opens the matching Privacy & Security pane in System Settings.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }
}
