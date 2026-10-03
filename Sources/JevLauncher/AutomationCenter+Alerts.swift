import AppKit
import LauncherCore

/// Notch alerts for runs that need the user, the opt-in running indicator, and Codex reading.
/// The decisions are `AlertDecision` in LauncherCore. Button handling is in `+AlertActions`.
extension AutomationCenter {
    nonisolated static func alertID(_ run: RunRecord) -> String { "run:\(run.automationID)/\(run.id)" }
    nonisolated static func runningAlertID(_ run: RunRecord) -> String { "running:\(run.automationID)/\(run.id)" }
    nonisolated static func resultAlertID(_ run: RunRecord) -> String { "result:\(run.automationID)/\(run.id)" }

    /// Shows alerts for runs that reached an alerting state. Quiet hours delay them until the period ends.
    func processAlerts(now: Date = Date()) {
        guard !isolated else { return }
        let settings = alertSettings()
        let notch = NotchAlertController.shared
        notch.failureSeconds = settings.failureSeconds
        var wake: Date?
        let all = runs.values.flatMap { $0 }
        let candidates = all.filter { !$0.alerted }.sorted { $0.queued < $1.queued }
        for run in candidates where !shownAlerts.contains(Self.alertID(run)) {
            let a = automation(run.automationID)
            switch AlertDecision.decide(run, policy: a?.policy, settings: settings, now: now) {
            case .show: show(run, automation: a, hideNames: settings.hideNames)
            case .wait(let until): wake = min(wake ?? until, until)
            case .skip: break
            }
        }
        // The live indicator: shown while a run is running, removed when it stops or the setting is off.
        var live: Set<String> = []
        for run in all where run.state == .running {
            switch AlertDecision.decideRunning(run, settings: settings, now: now) {
            case .show:
                live.insert(run.id)
                notch.show(Self.runningAlert(run, automation: automation(run.automationID), hideNames: settings.hideNames))
            case .wait(let until): wake = min(wake ?? until, until)
            case .skip: break
            }
        }
        for runID in runningAlerts.subtracting(live) { notch.withdraw(runID: runID, kinds: [.running]) }
        runningAlerts = live
        quietTask?.cancel()
        if let wake {
            quietTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, wake.timeIntervalSinceNow) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.processAlerts()
            }
        }
    }

    /// Queues the alert. Queueing is not delivery: the run counts as alerted only when the notch reports
    /// the alert as drawn on screen (`alertPresented`), so a locked screen or quiet queue keeps it pending.
    private func show(_ run: RunRecord, automation a: Automation?, hideNames: Bool) {
        let alert = Self.makeAlert(run, automation: a, hideNames: hideNames)
        shownAlerts.insert(alert.id)
        NotchAlertController.shared.show(alert)
        if run.state == .needsApproval { loadCounts(run, automation: a, hideNames: hideNames) }
    }

    /// The notch drew `alert` on screen. Saves the presentation proof (for a run that offers reports) and
    /// then the delivery receipt. The proof comes first: a receipt without its proof would stop the alert
    /// from showing again while the report still lacks evidence. A failed write is shown, never hidden.
    func alertPresented(_ alert: NotchAlert, now: Date = Date()) {
        guard !isolated, alert.id.hasPrefix("run:"), let ids = Self.alertRunIDs(alert.id),
              let run = runs[ids.automationID]?.first(where: { $0.id == ids.runID }) else { return }
        let store = self.store
        Task { @MainActor [weak self] in
            let failure = await Task.detached(priority: .utility) { () -> String? in
                // The record on disk decides: an alert for a state the run has left is not delivery.
                guard let current = store.run(automationID: run.automationID, runID: run.id),
                      AutomationAlertReceipt(current) == AutomationAlertReceipt(run) else { return nil }
                do {
                    if current.state == .succeeded {
                        try AutomationCenter.savePresentationProof(current, alertID: alert.id, store: store, now: now)
                    }
                    try AutomationAlertReceipt.save(current, store: store)
                    return nil
                } catch {
                    return "Jevcast showed “\(current.automationName)” but could not record that it did (\(error)). It may show again."
                }
            }.value
            AutomationSignal.post()
            if let failure {
                NSLog("Jevcast automations: %@", failure)
                self?.message = failure
            }
        }
    }

    /// Writes `presentation.json` once, with the reports the run offered, for the publish script.
    nonisolated static func savePresentationProof(_ run: RunRecord, alertID: String, store: AutomationStore, now: Date) throws {
        guard let data = try store.readRunFile(automationID: run.automationID, runID: run.id, name: PublicationRecord.fileName),
              let record = try? JSONDecoder().decode(PublicationRecord.self, from: data),
              record.runID == run.id, record.automationID == run.automationID else { return }
        let pending = record.items.filter { $0.state == .pending }
        guard !pending.isEmpty,
              (try? store.readRunFile(automationID: run.automationID, runID: run.id, name: PresentationProof.fileName)) == nil else { return }
        let proof = PresentationProof(automationID: run.automationID, runID: run.id, alertID: alertID, presentedAt: now, items: pending)
        try store.writeRunFile(automationID: run.automationID, runID: run.id, name: PresentationProof.fileName,
                               data: PresentationProof.encoder().encode(proof))
    }

    /// Reads the checked proposal and adds its counts and Approve all to the approval alert.
    private func loadCounts(_ run: RunRecord, automation a: Automation?, hideNames: Bool) {
        let expected = Self.makeAlert(run, automation: a, hideNames: hideNames)
        Task { @MainActor [weak self] in
            guard let self, case .success(let manifest)? = await self.proposal(for: run),
                  Self.canAddCounts(expected: expected, current: NotchAlertController.shared.alert(expected.id)) else { return }
            var alert = expected
            Self.addCounts(Self.counts(manifest), to: &alert)
            alert.approvalManifest = manifest
            NotchAlertController.shared.update(alert)
        }
    }

    nonisolated static func canAddCounts(expected: NotchAlert, current: NotchAlert?) -> Bool {
        expected.kind == .approval && current == expected
    }

    // MARK: Alert content (pure, for tests)

    /// The alert for a run that needs the user or failed.
    nonisolated static func makeAlert(_ run: RunRecord, automation a: Automation?, hideNames: Bool) -> NotchAlert {
        let text = AlertText.make(run, name: a?.name ?? run.automationName, hideNames: hideNames)
        let symbol = hideNames ? "bolt.badge.clock" : (a?.symbol ?? "gearshape.2")
        var alert = NotchAlert(id: alertID(run), kind: .info, symbol: symbol, title: text.title, message: text.message,
                               automationID: run.automationID, runID: run.id)
        switch run.state {
        case .needsInput:
            let question = run.questions.last { $0.answer == nil }
            alert.kind = .question
            if !hideNames, let question {
                alert.message = String(question.text.prefix(160))
                alert.choices = Array(question.choices.prefix(4))
            }
            alert.allowsReply = !hideNames
            alert.actions = (alert.allowsReply ? [.init("Reply…", id: NotchAlert.replyAction, primary: alert.choices.isEmpty)] : [])
                + [.init("Open", id: "answer", primary: !alert.allowsReply), .init("Later", id: "later")]
        case .needsApproval:
            alert.kind = .approval
            alert.actions = [.init("Review", id: "review", primary: true), .init("Later", id: "later")]
        case .failed, .interrupted:
            alert.kind = .failure
            alert.actions = [.init("Retry", id: "retry", primary: true), .init("Open", id: "open"), .init("Dismiss", id: "dismiss")]
        case .succeeded:
            // Opt-in: a report is ready or a backup finished. Open shows the saved result.
            alert.kind = .success
            alert.actions = [.init("Open", id: "open", primary: true), .init("Dismiss", id: "dismiss")]
        default:
            alert.actions = [.init("Open", id: "open", primary: true), .init("Later", id: "later")]
        }
        alert.tone = NotchAlert.tone(for: alert.kind)
        return alert
    }

    /// Counts by operation. Refused items are counted apart and never applied.
    nonisolated static func counts(_ manifest: ProposalManifest) -> NotchAlert.ApprovalCounts {
        var c = NotchAlert.ApprovalCounts()
        for item in manifest.checked {
            switch item.item.op {
            case .move: c.moves += 1
            case .rename: c.renames += 1
            case .mkdir: c.folders += 1
            case .trash: c.trash += 1
            case .tag: c.tags += 1
            }
        }
        c.refused = manifest.refused.count
        return c
    }

    nonisolated static func addCounts(_ counts: NotchAlert.ApprovalCounts, to alert: inout NotchAlert) {
        alert.counts = counts
        alert.message = counts.summary
        guard counts.total > 0 else { return }
        alert.actions = [.init("Approve all", id: "approveAll", primary: true), .init("Review", id: "review"), .init("Later", id: "later")]
    }

    /// The live indicator. Detail is the run's latest summary line, when it has one.
    nonisolated static func runningAlert(_ run: RunRecord, automation a: Automation?, hideNames: Bool) -> NotchAlert {
        let summary = run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = hideNames || summary.isEmpty ? (run.attempt > 1 ? "Attempt \(run.attempt)" : nil) : String(summary.prefix(120))
        return NotchAlert(id: runningAlertID(run), kind: .running, symbol: hideNames ? "gearshape.2" : (a?.symbol ?? "gearshape.2"),
                          title: hideNames ? "An automation" : (a?.name ?? run.automationName), message: "Running",
                          detail: detail, started: run.started,
                          actions: [.init("Cancel", id: "cancel", role: .destructive), .init("Open", id: "open")],
                          automationID: run.automationID, runID: run.id)
    }

    // MARK: Codex

    /// Reads `~/.codex/automations` off the main thread. Never writes there.
    func loadCodex() {
        guard !isolated else { return }
        Task { @MainActor [weak self] in
            let list = await Task.detached(priority: .utility) { CodexImport.readAll(folder: Self.codexFolder) }.value
            guard let self, self.codex != list else { return }
            self.codex = list
        }
    }
}
