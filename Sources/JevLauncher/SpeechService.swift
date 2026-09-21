import AVFoundation
import Combine
import Speech

/// Owns the short-lived microphone stream used for speech input.
///
/// The service uses the Mac's system input device. It never writes audio to
/// disk, and it never asks for permissions as a side effect of `start()`.
@MainActor
final class SpeechService: ObservableObject {
    @Published private(set) var status: String = "Speech input is idle. Using the system microphone."
    @Published private(set) var isListening = false

    var onTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionToken: UInt64 = 0
    private var tapInstalled = false

    /// True only when both permissions were already granted by the user.
    var permissionsGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Explicitly request the two permissions needed for speech input.
    /// `start()` deliberately does not call this method.
    func requestPermissions() async {
        let microphoneGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        let speechAuthorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorization in
                continuation.resume(returning: authorization)
            }
        }

        guard microphoneGranted else {
            status = "Microphone access is unavailable. Allow microphone access in System Settings, then try again."
            return
        }

        guard speechAuthorization == .authorized else {
            status = "Speech Recognition access is unavailable. Allow it in System Settings, then try again."
            return
        }

        status = "Permissions granted. Speech input is ready. Using the system microphone."
    }

    /// Starts a new on-device recognition session when permissions are ready.
    func start() {
        guard !isListening else { return }

        guard permissionsGranted else {
            status = "Speech input is unavailable. Grant microphone and Speech Recognition access first."
            return
        }

        guard let recognizer else {
            status = "Speech recognition is unavailable for the current language."
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            status = "On-device speech recognition is unavailable on this Mac. No cloud audio will be used."
            return
        }

        cancelCapture()
        sessionToken &+= 1
        let token = sessionToken

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription

            // Extract value types before crossing back to the main actor.
            Task { @MainActor [weak self] in
                guard let self, self.sessionToken == token, self.isListening else { return }

                if !transcript.isEmpty {
                    self.onTranscript?(transcript)
                }

                if let errorMessage {
                    self.finishCapture(status: "Speech recognition unavailable: \(errorMessage)")
                } else if isFinal {
                    self.finishCapture(status: "Speech recognition finished.")
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            finishCapture(status: "No system microphone input is available.")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            status = "Listening with on-device speech recognition. Using the system microphone."
        } catch {
            finishCapture(status: "Could not start the system microphone: \(error.localizedDescription)")
        }
    }

    /// Stops recognition and invalidates callbacks from the previous session.
    func stop() {
        finishCapture(status: "Speech input stopped.")
    }

    private func finishCapture(status: String) {
        sessionToken &+= 1
        cancelCapture()
        isListening = false
        self.status = status
    }

    private func cancelCapture() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
