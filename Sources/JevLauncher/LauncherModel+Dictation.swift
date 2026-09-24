import Foundation
import LauncherCore

/// Dictation clean-up. Local clean-up always runs; Luna runs only when the user allows
/// "Dictation transcripts", and `sendLuna` checks that switch again for each request.
extension LauncherModel {
    static let dictationLunaTimeout: UInt64 = 1_500_000_000

    struct CleanedDictation: Equatable {
        let text: String
        let usedLuna: Bool
    }

    func cleanDictation(_ transcript: String) async -> CleanedDictation {
        // Transcription follows the Mac's language; filler words are removed only in English.
        let local = DictationText.clean(transcript, fillers: Locale.current.language.languageCode == .english)
        guard !local.isEmpty, local.count <= LunaRequest.maxDictation,
              preferences.lunaEnabled, preferences.lunaSendsDictation else { return .init(text: local, usedLuna: false) }
        let request = LunaRequest.cleanDictation(local)
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor [weak self] in try? await self?.sendLuna(request).text }
            group.addTask { try? await Task.sleep(nanoseconds: Self.dictationLunaTimeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // Luna may only tidy what was said. A reply that adds or answers is dropped.
        guard let reply, DictationText.isFaithful(reply, to: local) else { return .init(text: local, usedLuna: false) }
        return .init(text: reply, usedLuna: true)
    }
}
