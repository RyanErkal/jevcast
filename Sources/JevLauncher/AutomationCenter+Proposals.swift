import CryptoKit
import Foundation
import LauncherCore

/// Proposal checking, approval, and undo. The runner only saves the agent's raw proposal;
/// the app checks it against the user's roots, applies approved items, and records the outcome.
extension AutomationCenter {
    static let proposalFile = "proposal.json"
    /// SHA-256 of the raw proposal that `proposal.json` was checked from, so a revised proposal is checked again.
    static let proposalSourceFile = "proposal-source.txt"

    /// Checks the agent's raw proposal against the automation's roots and caches `proposal.json`.
    func proposal(for run: RunRecord) -> Result<ProposalManifest, ProposalError>? {
        if let cached = proposals[run.id] { return cached }
        guard let raw = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: RunEngine.proposalRawFile) else { return nil }
        let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        if let stored = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: Self.proposalSourceFile),
           String(decoding: stored, as: UTF8.self) == hash,
           let data = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: Self.proposalFile),
           let manifest = try? AutomationJSON.decoder().decode(ProposalManifest.self, from: data) {
            proposals[run.id] = .success(manifest)
            return .success(manifest)
        }
        let result = ProposalValidator.check(rawJSON: raw, roots: roots(for: run.automationID), now: run.finished ?? Date())
        if case .success(let manifest) = result, let data = try? AutomationJSON.encoder().encode(manifest) {
            try? store.writeRunFile(automationID: run.automationID, runID: run.id, name: Self.proposalFile, data: data)
            try? store.writeRunFile(automationID: run.automationID, runID: run.id, name: Self.proposalSourceFile, data: Data(hash.utf8))
        }
        if run.state == .needsApproval { proposals[run.id] = result }
        return result
    }

    /// The working folder and allowed roots of the automation's agent. Roots come only from the user's definition.
    func roots(for automationID: String) -> [String] {
        guard let a = automation(automationID) else { return [] }
        let task: AgentTask
        switch a.kind {
        case .agent(let t): task = t
        case .scriptWithDiagnosis(_, let t): task = t
        case .script: return []
        }
        return ([task.workingDirectory] + task.allowedRoots).filter { !$0.isEmpty }.map { ($0 as NSString).expandingTildeInPath }
    }

    /// Applies the chosen items, records the journal, and marks the run succeeded.
    func approve(_ run: RunRecord, items: Set<String>) -> ApplyJournal? {
        guard var current = store.run(automationID: run.automationID, runID: run.id), current.state == .needsApproval else {
            message = "This run no longer waits for approval."; return nil
        }
        guard case .success(let manifest)? = proposal(for: current) else { message = "The proposal could not be checked."; return nil }
        let now = Date()
        if ProposalValidator.isExpired(manifest, now: now) {
            current.state = .expired; current.finished = now; current.summary = "Proposal expired after 7 days"
            saveApproval(current)
            message = "This proposal is older than 7 days. Run the automation again for a fresh one."
            return nil
        }
        guard let a = automation(current.automationID), a.revision == current.revision else {
            message = "The automation changed after this proposal. Run it again for a fresh one."; return nil
        }
        // Check again now: files may have moved since the proposal was shown. Apply only items that still pass,
        // bound to the identities the user saw.
        guard let raw = try? store.readRunFile(automationID: current.automationID, runID: current.id, name: RunEngine.proposalRawFile),
              case .success(let fresh) = ProposalValidator.check(rawJSON: raw, roots: roots(for: current.automationID), now: now),
              fresh.digest == manifest.digest else {
            message = "The proposal changed or could not be checked again."; return nil
        }
        let stillValid = Set(fresh.checked.map(\.id))
        let shown = Set(manifest.checked.map(\.id))
        let approved = items.filter { stillValid.contains($0) && shown.contains($0) }
        guard !approved.isEmpty else { message = "None of the chosen items can be applied now."; return nil }

        current.state = .applying
        saveApproval(current)
        let journalURL = store.runFolder(automationID: current.automationID, runID: current.id).appendingPathComponent(ApplyJournal.fileName)
        var journal = ProposalApplier(manifest: manifest, approved: approved, journalURL: journalURL).apply()
        // Chosen items that failed the second check are recorded as skipped.
        for id in items.subtracting(approved).sorted() {
            var entry = ApplyJournal.Entry(itemID: id, op: manifest.proposal.items.first { $0.id == id }?.op ?? .move,
                                           source: "", destination: nil, status: .skipped)
            entry.message = fresh.refused[id] ?? "No longer passes the check"
            journal.entries.append(entry)
        }
        current.journalFile = ApplyJournal.fileName
        current.state = journal.failed ? .failed : .succeeded
        current.summary = journal.summaryText
        current.error = journal.failed ? journal.entries.first { $0.status == .failed }?.message : nil
        current.finished = Date()
        // The user saw it; no alert for this outcome.
        current.alerted = true
        saveApproval(current)
        proposals[current.id] = nil
        NotchAlertController.shared.withdraw(id: Self.alertID(current))
        return journal
    }

    func reject(_ run: RunRecord) {
        guard var current = store.run(automationID: run.automationID, runID: run.id), current.state == .needsApproval else { return }
        current.state = .rejected; current.finished = Date(); current.summary = "Rejected"; current.alerted = true
        saveApproval(current)
        proposals[current.id] = nil
        NotchAlertController.shared.withdraw(id: Self.alertID(current))
    }

    func journal(for run: RunRecord) -> ApplyJournal? {
        guard let data = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: ApplyJournal.fileName) else { return nil }
        return ApplyJournal.decode(data)
    }

    func undo(_ run: RunRecord) -> ApplyJournal? {
        guard let journal = journal(for: run),
              let data = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: Self.proposalFile),
              let manifest = try? AutomationJSON.decoder().decode(ProposalManifest.self, from: data),
              manifest.digest == journal.digest else { message = "There is nothing to undo."; return nil }
        let journalURL = store.runFolder(automationID: run.automationID, runID: run.id).appendingPathComponent(ApplyJournal.fileName)
        let result = ProposalApplier(manifest: manifest, approved: Set(journal.approvedItems), journalURL: journalURL).undo(journal: journal)
        if var current = store.run(automationID: run.automationID, runID: run.id) {
            let undone = result.entries.filter { $0.status == .undone }.count
            let blocked = result.entries.filter { $0.status == .undoBlocked }.count
            current.summary = "Undid \(undone)" + (blocked > 0 ? ", \(blocked) could not be undone" : "")
            saveApproval(current)
        }
        return result
    }

    /// Saves an approval outcome and refreshes. The app writes only approval fields; the runner owns the rest.
    func saveApproval(_ run: RunRecord) {
        do { try store.saveRun(run) } catch { message = "Could not save the run: \(error)" }
        if !isolated { AutomationSignal.post() }
        scheduleReload()
    }
}
