import AVFoundation
import Speech

/// On-device transcription with SpeechAnalyzer and SpeechTranscriber (macOS 26).
@available(macOS 26, *)
final class AppleSpeechEngine: DictationEngine {
    let name = "apple-speech"

    private func transcriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw LauncherError("On-device transcription is not available on this Mac.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw LauncherError("Dictation does not support the language of this Mac yet.")
        }
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func prepare(status: @escaping @MainActor (String) -> Void) async throws {
        try await ensureAssets(for: transcriber(), status: status)
    }

    private func ensureAssets(for transcriber: SpeechTranscriber, status: @escaping @MainActor (String) -> Void) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return
        case .unsupported: throw LauncherError("Dictation does not support the language of this Mac yet.")
        case .supported, .downloading:
            await status("Downloading the speech model…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        @unknown default: return
        }
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) async throws -> String {
        let transcriber = try await transcriber()
        try await ensureAssets(for: transcriber, status: { _ in })
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format) ?? format
        let converter = PCMConverter(from: format, to: target)
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let collector = Task { () throws -> String in
            var parts: [String] = []
            for try await result in transcriber.results { parts.append(String(result.text.characters)) }
            return parts.joined(separator: " ")
        }
        try await analyzer.start(inputSequence: inputs)
        for await buffer in audio {
            if let converted = converter.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
        }
        feed.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { collector.cancel(); throw error }
        return try await collector.value
    }
}

/// Converts microphone buffers to the analyzer's format, in memory.
private struct PCMConverter {
    let converter: AVAudioConverter?
    let target: AVAudioFormat
    init(from source: AVAudioFormat, to target: AVAudioFormat) {
        self.target = target
        converter = source == target ? nil : AVAudioConverter(from: source, to: target)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
