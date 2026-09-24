import AppKit
import LauncherCore

/// "dictation history": past dictations, newest first. Paste one again or copy it.
@MainActor
final class DictationSource: ThingSource {
    let section = "Dictation History"
    private let store: TranscriptStore
    init(store: TranscriptStore = TranscriptStore(folder: DictationController.folder)) { self.store = store }

    func load(_ filter: String) async throws -> [LauncherResult] {
        let all = store.all()
        let matches = filter.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(filter) }
        guard !matches.isEmpty else {
            throw SourceProblem(text: all.isEmpty ? "No dictations yet. Turn on dictation in Settings › Dictation, then hold Right Command." : "No dictation matches.")
        }
        return matches.prefix(100).enumerated().map { index, entry in
            let text = entry.text
            let paste = Verb(title: "Paste Again", after: .close) { copyText(text); Paster.pasteSoon(); return nil }
            let copy = Verb(title: "Copy", after: .stay) { copyText(text); return "Copied." }
            return LauncherResult(id: "dictation:\(entry.date.timeIntervalSince1970)", title: text,
                                  detail: entry.date.formatted(.relative(presentation: .named)),
                                  symbol: "waveform", action: .thing(Thing(verbs: [paste, copy])), score: 3000 - Double(index))
        }
    }
}
