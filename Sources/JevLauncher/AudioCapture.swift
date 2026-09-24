import AVFoundation

/// Microphone audio for one dictation. Buffers stay in memory and are never written to disk.
@MainActor
final class AudioCapture {
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Starts the microphone. The stream ends when `stop()` runs.
    func start() throws -> (audio: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw LauncherError("No microphone is available.") }
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .unbounded)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in continuation.yield(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw LauncherError("The microphone could not start.")
        }
        self.engine = engine
        self.continuation = continuation
        return (stream, format)
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
    }
}
