import AVFoundation

/// Turns microphone audio into text on this Mac. Audio never leaves the device.
protocol DictationEngine: AnyObject {
    /// Stored with each transcript, such as "apple-speech".
    var name: String { get }
    /// Downloads the language model if needed. `status` reports progress text for the overlay.
    func prepare(status: @escaping @MainActor (String) -> Void) async throws
    /// Reads `audio` until the stream ends, then returns the whole transcript.
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) async throws -> String
}

enum DictationEngines {
    /// Dictation needs SpeechAnalyzer, so the feature is hidden before macOS 26.
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static func make() -> DictationEngine? {
        if #available(macOS 26, *) { return AppleSpeechEngine() }
        return nil
    }
}
