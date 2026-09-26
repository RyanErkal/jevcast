import Foundation
import LauncherCore

/// Dictation clean-up. Local clean-up always runs; Quill runs only when the user allows
/// "Dictation transcripts", and `sendQuill` checks that switch again for each request.
extension LauncherModel {
    static let dictationQuillTimeout: UInt64 = 1_500_000_000

    struct CleanedDictation: Equatable {
        let text: String
        let usedQuill: Bool
    }

    func cleanDictation(_ transcript: String) async -> CleanedDictation {
        // Transcription follows the Mac's language; filler words are removed only in English.
        let local = DictationText.clean(transcript, fillers: Locale.current.language.languageCode == .english)
        guard !local.isEmpty, local.count <= QuillRequest.maxDictation,
              preferences.quillEnabled, preferences.quillSendsDictation else { return .init(text: local, usedQuill: false) }
        let request = QuillRequest.cleanDictation(local)
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor [weak self] in try? await self?.sendQuill(request).text }
            group.addTask { try? await Task.sleep(nanoseconds: Self.dictationQuillTimeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // Quill may only tidy what was said. A reply that adds or answers is dropped.
        guard let reply, DictationText.isFaithful(reply, to: local) else { return .init(text: local, usedQuill: false) }
        return .init(text: reply, usedQuill: true)
    }
}
