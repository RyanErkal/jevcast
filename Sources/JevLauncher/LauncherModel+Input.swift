import AppKit

extension LauncherModel {
    /// A held Return is still the same press, including at a confirmation row.
    @discardableResult
    func handleSearchReturn(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        if !event.isARepeat && !isComposingSearch { execute(paste: event.modifierFlags.contains(.shift)) }
        return true
    }

    func updateSearchField(_ text: String, composing: Bool) {
        let wasComposing = isComposingSearch
        isComposingSearch = composing
        if composing {
            acceptsSpeech = false; speech.stop()
            revision = UUID()
            cancelSearchWork()
            return
        }
        updateQuery(text, typed: true, force: wasComposing)
    }
}
