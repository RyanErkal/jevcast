import AppKit
import AVFoundation
import Speech
import IOKit.hid

enum Permission: CaseIterable {
    case microphone, speech, accessibility, inputMonitoring

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }
    var purpose: String {
        switch self {
        case .microphone: return "Hears spoken commands"
        case .speech: return "Transcribes speech on this Mac"
        case .accessibility: return "Moves and resizes windows"
        case .inputMonitoring: return "Hyper key and its Caps Lock light"
        }
    }
    @MainActor var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: return WindowManager.hasPermission
        case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }
    private var pane: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .speech: return "Privacy_SpeechRecognition"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
    /// True before the first request. Accessibility has no such state: it is granted in System Settings.
    @MainActor var isUndetermined: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .speech: return SFSpeechRecognizer.authorizationStatus() == .notDetermined
        case .accessibility: return false
        case .inputMonitoring: return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown
        }
    }
    /// Opens the matching Privacy & Security pane in System Settings.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Permission {
    /// Asks once while undetermined, then opens System Settings.
    @MainActor static func requestInputMonitoring() {
        if Permission.inputMonitoring.isUndetermined { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        else { Permission.inputMonitoring.openSystemSettings() }
    }
}
