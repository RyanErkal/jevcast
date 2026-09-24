import AppKit

/// One action on a thing: Switch to a tab, Complete a reminder, Run a job now.
/// Verbs only run fixed code with the thing's own values. Nothing becomes shell text.
struct Verb {
    /// What the launcher does after the verb succeeds.
    enum After {
        /// Close and return focus to the previous app.
        case close
        /// Close and leave focus where the verb put it, for a verb that opens something.
        case closeKeepFocus
        /// Stay open, show the verb's message, and reload the list.
        case stay
    }
    let title: String
    var key: String = ""
    /// Return asks twice for a disruptive primary verb. The actions menu is already deliberate.
    var confirm = false
    var after: After = .closeKeepFocus
    /// Returns a short confirmation for the strip, such as "Turned off com.example.sync".
    let run: @MainActor () async throws -> String?
}

/// A row from a source: a scheduled job, an event, a reminder, a contact, a tab, a message.
/// The first verb is what Return does; ⌘K lists every verb.
struct Thing {
    let verbs: [Verb]
    var path: String?
    var twoLine = true
    var primary: Verb? { verbs.first }
}

extension LauncherModel {
    /// Runs a verb on a thing row. Closing verbs close first, so a slow verb never holds the panel.
    func run(_ verb: Verb, on result: LauncherResult) {
        switch verb.after {
        case .close, .closeKeepFocus:
            learnFromExecution(result)
            onClose?(verb.after == .close)
            Task { @MainActor [weak self] in
                do { _ = try await verb.run() } catch { self?.showFailure(error.localizedDescription) }
            }
        case .stay:
            let current = revision
            Task { @MainActor [weak self] in
                do {
                    let note = try await verb.run()
                    guard let self, self.visible, self.revision == current else { return }
                    self.message = nil; self.sourceNote = note
                    self.reloadSource()
                } catch {
                    guard let self, self.visible else { return }
                    self.message = error.localizedDescription
                }
            }
        }
    }
}
