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
        let local = DictationText.clean(transcript)
        guard !local.isEmpty, preferences.lunaEnabled, preferences.lunaSendsDictation else { return .init(text: local, usedLuna: false) }
        let request = LunaRequest.cleanDictation(local)
        let reply: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor [weak self] in try? await self?.sendLuna(request).text }
            group.addTask { try? await Task.sleep(nanoseconds: Self.dictationLunaTimeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let reply, !reply.isEmpty else { return .init(text: local, usedLuna: false) }
        return .init(text: reply, usedLuna: true)
    }
}
