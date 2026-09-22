import AVFoundation
import Combine
import os.log
@preconcurrency import Speech

/// Owns the short-lived microphone stream used for speech input.
///
/// The service uses the Mac's system input device. It never writes audio to
/// disk, and it never asks for permissions as a side effect of `start()`.
@MainActor
final class SpeechService: ObservableObject {
    @Published private(set) var status: String = "Speech input is idle."
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    /// Set when a session ends with a failure; cleared on the next start or stop.
    @Published private(set) var errorMessage: String?

    var onTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let captureWorker = CaptureWorker()
    private let logger = Logger(subsystem: "com.jevlauncher", category: "SpeechService")
    private var sessionToken: UInt64 = 0
    private var startRequestedAt: UInt64?

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
            status = "Microphone access denied. Allow it in System Settings."
            return
        }

        guard speechAuthorization == .authorized else {
            status = "Speech Recognition denied. Allow it in System Settings."
            return
        }

        status = "Speech input is ready."
    }

    /// Starts a new on-device recognition session when permissions are ready.
    func start() {
        guard !isListening, !isStarting else { return }

        guard permissionsGranted else {
            status = "Voice needs microphone and speech access."
            return
        }

        guard let recognizer else {
            status = "Speech recognition is unavailable for the current language."
            return
        }

        guard recognizer.supportsOnDeviceRecognition else {
            status = "On-device speech recognition is unavailable on this Mac."
            return
        }

        sessionToken &+= 1
        let token = sessionToken
        isStarting = true
        errorMessage = nil
        startRequestedAt = DispatchTime.now().uptimeNanoseconds
        status = "Starting speech input…"

        // DispatchQueue.main keeps events in order, so an older partial transcript cannot land after a newer one.
        captureWorker.start(token: token, recognizer: recognizer) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(event, token: token) }
            }
        }
    }

    /// Stops recognition and invalidates callbacks from the previous session.
    func stop() {
        sessionToken &+= 1
        isStarting = false
        isListening = false
        startRequestedAt = nil
        status = "Speech input stopped."
        errorMessage = nil
        captureWorker.stop()
    }

    private func receive(_ event: CaptureWorker.Event, token: UInt64) {
        guard sessionToken == token else { return }

        switch event {
        case .listening:
            guard isStarting else { return }
            isStarting = false
            isListening = true
            status = "Listening."
            if let startRequestedAt {
                let elapsed = DispatchTime.now().uptimeNanoseconds &- startRequestedAt
                logger.debug("Speech input ready after \(elapsed / 1_000_000, privacy: .public) ms")
            }
            self.startRequestedAt = nil

        case let .recognition(transcript, isFinal, errorMessage):
            guard isStarting || isListening else { return }

            if !transcript.isEmpty {
                onTranscript?(transcript)
            }

            // A transcript callback can synchronously stop the service.
            guard sessionToken == token else { return }

            if let errorMessage {
                finish(status: "Speech recognition unavailable: \(errorMessage)", failed: true)
            } else if isFinal {
                finish(status: "Speech input finished.")
            }

        case let .failed(message):
            guard isStarting || isListening else { return }
            logger.error("Speech input failed: \(message, privacy: .public)")
            finish(status: message, failed: true)
        }
    }

    private func finish(status: String, failed: Bool = false) {
        sessionToken &+= 1
        isStarting = false
        isListening = false
        startRequestedAt = nil
        self.status = status
        errorMessage = failed ? status : nil
        captureWorker.stop()
    }
}

private final class CaptureWorker: @unchecked Sendable {
    enum Event: Sendable {
        case listening
        case recognition(transcript: String, isFinal: Bool, errorMessage: String?)
        case failed(String)
    }

    typealias EventHandler = @Sendable (Event) -> Void

    private let queue = DispatchQueue(label: "com.jevlauncher.speech.capture")
    private let requestLock = NSLock()
    private var requestedToken: UInt64?

    // These properties are accessed only by `queue` after initialization.
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeToken: UInt64?
    private var tapInstalled = false
    private var lastTranscript: String?
    private var configurationObserver: NSObjectProtocol?

    func start(token: UInt64, recognizer: SFSpeechRecognizer, handler: @escaping EventHandler) {
        requestLock.lock()
        requestedToken = token
        requestLock.unlock()

        queue.async { [weak self] in
            guard let self, self.isRequested(token) else { return }
            self.startOnQueue(token: token, recognizer: recognizer, handler: handler)
        }
    }

    func stop() {
        requestLock.lock()
        requestedToken = nil
        requestLock.unlock()

        queue.async { [weak self] in
            self?.cancelCaptureOnQueue()
        }
    }

    private func startOnQueue(token: UInt64, recognizer: SFSpeechRecognizer, handler: @escaping EventHandler) {
        cancelCaptureOnQueue()
        guard isRequested(token) else { return }

        // A fresh engine per session picks up the current input device and format.
        let engine = AVAudioEngine()
        audioEngine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.activeToken == token else { return }
                self.failOnQueue(token: token, message: "Audio input changed · tap mic to retry", handler: handler)
            }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        activeToken = token
        lastTranscript = nil
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let transcript = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            self.queue.async { [weak self] in
                guard let self else { return }
                self.handleRecognitionOnQueue(
                    token: token,
                    transcript: transcript,
                    isFinal: isFinal,
                    errorMessage: errorMessage,
                    handler: handler
                )
            }
        }

        guard isRequested(token) else {
            cancelCaptureOnQueue()
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            failOnQueue(token: token, message: "No system microphone input is available.", handler: handler)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self, weak request] buffer, _ in
            guard let self, self.isRequested(token) else { return }
            request?.append(buffer)
        }
        tapInstalled = true

        guard isRequested(token) else {
            cancelCaptureOnQueue()
            return
        }

        engine.prepare()
        guard isRequested(token) else {
            cancelCaptureOnQueue()
            return
        }

        do {
            try engine.start()
        } catch {
            failOnQueue(
                token: token,
                message: "Could not start the system microphone: \(error.localizedDescription)",
                handler: handler
            )
            return
        }

        guard isRequested(token) else {
            cancelCaptureOnQueue()
            return
        }

        handler(.listening)
    }

    private func handleRecognitionOnQueue(
        token: UInt64,
        transcript: String,
        isFinal: Bool,
        errorMessage: String?,
        handler: @escaping EventHandler
    ) {
        guard activeToken == token, isRequested(token) else { return }

        let changedTranscript = !transcript.isEmpty && transcript != lastTranscript
        if changedTranscript {
            lastTranscript = transcript
        }

        if changedTranscript || isFinal || errorMessage != nil {
            handler(.recognition(
                transcript: changedTranscript ? transcript : "",
                isFinal: isFinal,
                errorMessage: errorMessage
            ))
        }

        if isFinal || errorMessage != nil {
            cancelCaptureOnQueue()
        }
    }

    private func failOnQueue(token: UInt64, message: String, handler: @escaping EventHandler) {
        guard isRequested(token) else {
            cancelCaptureOnQueue()
            return
        }
        cancelCaptureOnQueue()
        handler(.failed(message))
    }

    private func isRequested(_ token: UInt64) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requestedToken == token
    }

    private func cancelCaptureOnQueue() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        // Remove the tap before stopping so no buffer arrives for a stopped engine.
        if tapInstalled, let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let audioEngine, audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine = nil

        activeToken = nil
        lastTranscript = nil
    }
}
