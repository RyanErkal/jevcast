import Foundation
import LauncherCore

/// What the notch buttons do for automation alerts. Every change goes through the same center methods
/// as the Automations window: `answer`, `approve`, `undo`, `cancel`, `runNow`.
extension AutomationCenter {
    enum ApproveAllOutcome: Equatable {
        case applied(ApplyJournal)
        /// Nothing changed. The text says why.
        case refused(String)
    }

    /// Splits "run:<automation>/<run>" into its IDs.
    nonisolated static func alertRunIDs(_ alertID: String) -> (automationID: String, runID: String)? {
        guard let colon = alertID.firstIndex(of: ":") else { return nil }
        let parts = alertID[alertID.index(after: colon)...].split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, AutomationID.isValid(parts[0]), RunID.isValid(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// Read the current record off the main thread. A missing record is not actionable.
    func currentRun(_ automationID: String, _ runID: String) async -> RunRecord? {
        let store = self.store
        return await Task.detached(priority: .userInitiated) {
            store.run(automationID: automationID, runID: runID)
        }.value
    }

    /// Handles a notch button for an automation alert. Returns false for alerts that are not ours.
    @discardableResult func handleAlertAction(_ alertID: String, _ action: String, approval: ProposalManifest? = nil) -> Bool {
        if alertID.hasPrefix("merged-") || alertID == NotchQueue.stackID {
            if ["open", "review", "answer"].contains(action) { openWindow?(nil, nil) }
            return true
        }
        let kind = alertID.prefix { $0 != ":" }
        guard ["run", "running", "result"].contains(kind) else { return false }
        guard let ids = Self.alertRunIDs(alertID) else { return true }
        switch action {
        case "review", "answer", "open": openWindow?(ids.automationID, ids.runID)
        // A blocked Retry opens the automation, where the window shows why.
        case "retry": if !runNow(ids.automationID), let a = automation(ids.automationID), runProblem(a) != nil { openWindow?(a.id, nil) }
        case "cancel", "approveAll", "undo":
            Task { @MainActor [weak self] in
                guard let self, let run = await self.currentRun(ids.automationID, ids.runID) else { return }
                if action == "cancel" {
                    if run.state.isActive { self.cancel(run) }
                } else if action == "approveAll" {
                    await self.approveAllFromNotch(run, shown: approval)
                } else if let result = await self.undo(run) {
                    let undone = result.entries.filter { $0.status == .undone }.count
                    let blocked = result.entries.filter { $0.status == .undoBlocked }.count
                    self.post(NotchAlert(id: Self.resultAlertID(run), kind: blocked > 0 ? .failure : .info, symbol: "arrow.uturn.backward",
                                         title: self.alertTitle(run), message: "Undid \(undone)" + (blocked > 0 ? ", \(blocked) could not be undone" : ""),
                                         actions: [.init("Open", id: "open")], automationID: run.automationID, runID: run.id))
                }
            }
        default:
            guard action.hasPrefix("reply:") || action.hasPrefix("choice:") else { return true }
            Task { @MainActor [weak self] in
                guard let self, let run = await self.currentRun(ids.automationID, ids.runID), run.state == .needsInput,
                      let text = Self.answerText(action, run: run) else { return }
                self.answer(run, text)
            }
        }
        return true
    }

    /// The answer a choice or reply button carries, or nil for other actions.
    nonisolated static func answerText(_ action: String, run: RunRecord?) -> String? {
        if action.hasPrefix("reply:") {
            let text = String(action.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(4000))
        }
        guard action.hasPrefix("choice:"), let index = Int(action.dropFirst(7)),
              let question = run?.questions.last(where: { $0.answer == nil }), question.choices.indices.contains(index) else { return nil }
        return question.choices[index]
    }

    nonisolated static func approvableItems(_ manifest: ProposalManifest) -> Set<String> {
        Set(manifest.checked.map(\.id)).subtracting(manifest.refused.keys)
    }

    /// Approves every item that passed the check, through `approve`, which checks each one again before it applies.
    /// Refused items are never included.
    func approveAll(_ run: RunRecord, shown: ProposalManifest?) async -> ApproveAllOutcome {
        guard let current = await currentRun(run.automationID, run.id), current.state == .needsApproval else {
            return .refused("This run no longer waits for approval.")
        }
        guard let manifest = shown else {
            return .refused("Review the checked proposal before approving it.")
        }
        let items = Self.approvableItems(manifest)
        guard !items.isEmpty else { return .refused("Nothing in this proposal can be applied.") }
        guard let journal = await approve(current, items: items, shown: manifest) else {
            return .refused(message ?? "The changes could not be applied.")
        }
        return .applied(journal)
    }

    /// Approve all from the notch, then a result with Undo for 10 seconds.
    private func approveAllFromNotch(_ run: RunRecord, shown: ProposalManifest?) async {
        post(NotchAlert(id: Self.resultAlertID(run), kind: .info, symbol: "hourglass", title: alertTitle(run),
                        message: "Applying changes…", automationID: run.automationID, runID: run.id))
        let outcome = await approveAll(run, shown: shown)
        post(Self.resultAlert(outcome, run: run, title: alertTitle(run)))
    }

    nonisolated static func resultAlert(_ outcome: ApproveAllOutcome, run: RunRecord, title: String) -> NotchAlert {
        switch outcome {
        case .applied(let journal):
            let applied = journal.entries.contains { $0.status == .done }
            return NotchAlert(id: resultAlertID(run), kind: journal.failed ? .failure : .success,
                              symbol: journal.failed ? "exclamationmark.triangle" : "checkmark.circle", title: title,
                              message: journal.summaryText,
                              actions: (applied ? [.init("Undo", id: "undo", primary: true)] : []) + [.init("Open", id: "open")],
                              automationID: run.automationID, runID: run.id)
        case .refused(let why):
            return NotchAlert(id: resultAlertID(run), kind: .failure, symbol: "exclamationmark.triangle", title: title,
                              message: why, actions: [.init("Review", id: "review", primary: true)],
                              automationID: run.automationID, runID: run.id)
        }
    }

    private func alertTitle(_ run: RunRecord) -> String {
        alertSettings().hideNames ? "An automation" : (automation(run.automationID)?.name ?? run.automationName)
    }

    /// Shows an alert unless this center is isolated for snapshots and tests.
    private func post(_ alert: NotchAlert) {
        guard !isolated else { return }
        NotchAlertController.shared.show(alert)
    }

    /// Whether a remembered alert still applies, for "Show notifications".
    func alertStillApplies(_ alert: NotchAlert) -> Bool {
        guard alert.id.hasPrefix("run:") || alert.id.hasPrefix("running:") || alert.id.hasPrefix("result:") else { return true }
        guard alert.id.hasPrefix("run:"), let ids = Self.alertRunIDs(alert.id),
              let run = runs[ids.automationID]?.first(where: { $0.id == ids.runID }) else { return false }
        return run.state.needsUser || run.state == .failed
    }

    // MARK: Test alerts

    /// A sample alert for Settings, with invented content. Buttons only close it.
    func showTestAlert(_ kind: NotchAlert.Kind = .info) {
        let hide = alertSettings().hideNames
        NotchAlertController.shared.failureSeconds = alertSettings().failureSeconds
        let title = hide ? "An automation" : "Sample automation"
        let id = "test-\(kind.rawValue)-\(UUID().uuidString)"
        let alert: NotchAlert
        switch kind {
        case .running:
            alert = NotchAlert(id: id, kind: .running, symbol: "gearshape.2", title: title, message: "Running",
                               detail: hide ? nil : "Reading the sample folder", started: Date().addingTimeInterval(-42),
                               actions: [.init("Cancel", id: "cancel", role: .destructive), .init("Open", id: "open")])
        case .question:
            alert = NotchAlert(id: id, kind: .question, symbol: "questionmark.bubble", title: title,
                               message: hide ? "It has a question for you." : "Which folder should the sample files go to?",
                               actions: [.init("Reply…", id: NotchAlert.replyAction), .init("Later", id: "later")],
                               choices: hide ? [] : ["Archive", "Documents"], allowsReply: !hide)
        case .approval:
            var counts = NotchAlert.ApprovalCounts(); counts.moves = 12; counts.trash = 3
            alert = NotchAlert(id: id, kind: .approval, symbol: "folder.badge.gearshape", title: title, message: counts.summary,
                               actions: [.init("Approve all", id: "later", primary: true),
                                         .init("Review", id: "later"), .init("Later", id: "later")], counts: counts)
        case .success:
            alert = NotchAlert(id: id, kind: .success, symbol: "checkmark.circle", title: title, message: "Moved 12, trashed 3",
                               actions: [.init("Undo", id: "later", primary: true), .init("Open", id: "later")])
        case .failure:
            alert = NotchAlert(id: id, kind: .failure, symbol: "exclamationmark.triangle", title: title,
                               message: hide ? "It failed." : "Failed: the sample source did not answer.",
                               actions: [.init("Retry", id: "later", primary: true), .init("Open", id: "later"), .init("Dismiss", id: "dismiss")])
        case .info:
            alert = NotchAlert(id: id, kind: .info, symbol: "bolt.badge.clock", title: hide ? "An automation" : "Test alert",
                               message: "Automation alerts look like this.", actions: [.init("OK", id: "later", primary: true)])
        }
        NotchAlertController.shared.show(alert)
    }
}
