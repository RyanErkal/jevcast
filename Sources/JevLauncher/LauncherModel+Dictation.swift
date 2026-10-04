import Foundation
import LauncherCore

/// Dictation clean-up. Local clean-up always runs; AI clean-up runs only when the user allows
/// "Dictation transcripts", and `sendAIWriting` checks that switch again for each request.
extension LauncherModel {
    static let dictationAIWritingTimeout: UInt64 = 1_500_000_000

    struct CleanedDictation: Equatable {
        let text: String
        let usedAIWriting: Bool
    }

    func cleanDictation(_ transcript: String) async -> CleanedDictation {
        // Transcription follows the Mac's language; filler words are removed only in English.
        let local = DictationText.clean(transcript, fillers: Locale.current.language.languageCode == .english)
        guard !local.isEmpty, local.count <= AIWritingRequest.maxDictation,
              preferences.aiWritingEnabled, preferences.aiWritingSendsDictation else { return .init(text: local, usedAIWriting: false) }
        let request = AIWritingRequest.cleanDictation(local)
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor [weak self] in try? await self?.sendAIWriting(request).text }
            group.addTask { try? await Task.sleep(nanoseconds: Self.dictationAIWritingTimeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // The writing model may only tidy what was said. A reply that adds or answers is dropped.
        guard let reply, DictationText.isFaithful(reply, to: local) else { return .init(text: local, usedAIWriting: false) }
        return .init(text: reply, usedAIWriting: true)
    }
}
